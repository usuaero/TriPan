module panel_solver_mod

    use helpers_mod
    use json_mod
    use json_xtnsn_mod
    use panel_mod
    use vertex_mod
    use surface_mesh_mod
    use flow_mod
    use math_mod

    implicit none


    type panel_solver


        character(len=:),allocatable :: formulation
        type(dod),dimension(:,:),allocatable :: dod_info
        type(flow) :: freestream

        contains

            procedure :: init => panel_solver_init
            procedure :: init_dirichlet => panel_solver_init_dirichlet
            procedure :: solve => panel_solver_solve
            procedure :: solve_dirichlet => panel_solver_solve_dirichlet

    end type panel_solver


contains


    subroutine panel_solver_init(this, settings, body, freestream)

        implicit none

        class(panel_solver),intent(inout) :: this
        type(json_value),pointer,intent(in) :: settings
        type(surface_mesh),intent(inout) :: body
        type(flow),intent(inout) :: freestream

        integer :: i, j

        ! Get settings
        call json_xtnsn_get(settings, 'formulation', this%formulation, 'morino')
        call json_xtnsn_get(settings, 'influence_calculations', influence_calc_type, 'johnson-ehlers')
        if (influence_calc_type == 'gaussian quad') then
            write(*,*) "    !!! Gaussian quadrature calculations are not yet implemented. Reverting to Johnson-Ehlers."
            influence_calc_type = 'johnson-ehlers'
        end if

        ! Store
        this%freestream = freestream

        ! Initialize based on formulation
        if (this%formulation == 'morino' .or. this%formulation == 'source-free') then
            call this%init_dirichlet(settings, body)
        end if

        ! Calculate domains of dependence
        ! For asymmetric flow on a mirrored mesh, all domains of dependence must be calculated. There are no shortcuts.
        ! For symmetric flow on a mirrored mesh, domains of dependence will be the same between mirrored panels and mirrored
        ! control points. So, we just need to calculate the DoD for mirrored control points, and then we're good.

        ! Allocate domains of dependence
        if (body%mirrored) then
            if (body%asym_flow) then
                allocate(this%dod_info(2*body%N_panels+body%wake%N_panels, 2*body%N_cp))
            else
                allocate(this%dod_info(body%N_panels+body%wake%N_panels, 2*body%N_cp))
            end if
        else
            allocate(this%dod_info(body%N_panels+body%wake%N_panels, body%N_cp))
        end if

        ! Loop through control points
        do j=1,body%N_cp

            ! Loop through body panels
            do i=1,body%N_panels

                ! Check DoD for original panel and original control point
                this%dod_info(i,j) = body%panels(i)%check_dod(body%control_points(j,:), this%freestream)

                if (body%mirrored) then

                    ! Check DoD for original panel and mirrored control point
                    this%dod_info(i,j+body%N_cp) = body%panels(i)%check_dod(body%cp_mirrored(j,:), this%freestream)

                    
                    if (body%asym_flow) then

                        ! Check DoD for mirrored panel and mirrored control point
                        this%dod_info(i+body%N_panels,j+body%N_cp) = body%panels(i)%check_dod(body%cp_mirrored(j,:), &
                                                                                              this%freestream, .true., &
                                                                                              body%mirror_plane)

                        ! Check DoD for mirrored panel and original control point
                        this%dod_info(i+body%N_panels,j) = body%panels(i)%check_dod(body%control_points(j,:), this%freestream, &
                                                                                    .true., body%mirror_plane)

                    end if

                end if

            end do

            ! Loop through wake panels
            do i=1,body%wake%N_panels

                ! Check DoD for panel and original control point
                this%dod_info(i+body%N_panels,j) = body%wake%panels(i)%check_dod(body%control_points(j,:), this%freestream)

                if (body%mirrored) then

                    ! Check DoD for panel and mirrored control point
                    this%dod_info(i+body%N_panels,j+body%N_cp) = body%wake%panels(i)%check_dod(body%cp_mirrored(j,:), &
                                                                                               this%freestream)

                    ! No other calculations are needed because mirrored panels are explicitly created in the case of asymmetric flow

                end if

            end do

        end do

    end subroutine panel_solver_init


    subroutine panel_solver_init_dirichlet(this, settings, body)
        ! Initializes the solver to use one of the Dirichlet formulations

        implicit none

        class(panel_solver),intent(in) :: this
        type(json_value),pointer,intent(in) :: settings
        type(surface_mesh),intent(inout) :: body

        real :: offset
        
        ! Place control points
        write(*,'(a)',advance='no') "     Placing control points..."

        ! Get offset
        call json_xtnsn_get(settings, 'control_point_offset', offset, 1e-5)

        ! Place control points inside the body
        if (this%formulation == 'morino' .or. this%formulation == 'source-free') then
            call body%place_interior_control_points(offset)
        end if

        write(*,*) "Done."
    
    end subroutine panel_solver_init_dirichlet


    subroutine panel_solver_solve(this, body, report_file)
        ! Calls the relevant subroutine to solve the case based on the selected formulation

        implicit none

        class(panel_solver),intent(inout) :: this
        type(surface_mesh),intent(inout) :: body
        character(len=:),allocatable :: report_file

        ! Dirichlet formulation
        if (this%formulation == 'morino' .or. this%formulation == 'source-free') then
            call this%solve_dirichlet(body, report_file)
        end if

    end subroutine panel_solver_solve


    subroutine panel_solver_solve_dirichlet(this, body, report_file)
        ! Solves one of the Dirichlet formulations for the given conditions

        implicit none

        class(panel_solver),intent(inout) :: this
        type(surface_mesh),intent(inout) :: body
        character(len=:),allocatable :: report_file

        integer :: i, j, k
        real,dimension(:),allocatable :: source_inf, doublet_inf
        integer,dimension(:),allocatable :: source_verts, doublet_verts
        real,dimension(:,:),allocatable :: A, A_copy
        real,dimension(:),allocatable :: b
        integer :: stat, N_sigma, N_mu, N_pressures
        real,dimension(3) :: n_mirrored, C_F
        real,dimension(:,:),allocatable :: dC_F
        logical :: morino

        ! Determine formulation
        morino = this%formulation == 'morino'

        ! Set source strengths
        write(*,'(a)',advance='no') "     Calculating source strengths..."
        if (source_order == 0) then

            ! Determine necessary number of source strengths
            if (body%mirrored .and. body%asym_flow) then
                N_sigma = body%N_panels*2
            else
                N_sigma = body%N_panels
            end if

            ! Allocate source strength array
            allocate(body%sigma(N_sigma))

            ! Morino formulation
            if (morino) then

                ! Loop through panels
                do i=1,body%N_panels

                    ! Existing panels
                    body%sigma(i) = inner(body%panels(i)%normal, this%freestream%c0)

                    ! Mirrored panels for asymmetric flow
                    if (body%mirrored .and. body%asym_flow) then

                        ! Get mirrored normal vector
                        n_mirrored = mirror_about_plane(body%panels(i)%normal, body%mirror_plane)

                        ! Calculate source strength
                        body%sigma(i+body%N_panels) = inner(n_mirrored, this%freestream%c0)

                    end if
                end do
            
            ! Source-free formulation
            else if (this%formulation == 'source-free') then
                body%sigma = 0.
            end if

        end if
        write(*,*) "Done."

        ! Determine number of doublet strengths (some will be repeats for mirrored vertices)
        if (body%mirrored .and. body%asym_flow) then
            N_mu = body%N_cp*2
        else
            N_mu = body%N_cp
        end if

        ! Allocate space for inner potential calculations
        allocate(body%phi_cp_sigma(N_mu), source=0., stat=stat)
        call check_allocation(stat, "induced potential vector")

        ! Allocate AIC matrix
        allocate(A(N_mu, N_mu), source=0., stat=stat)
        call check_allocation(stat, "AIC matrix")

        ! Allocate b vector
        allocate(b(N_mu), source=0., stat=stat)
        call check_allocation(stat, "b vector")

        write(*,'(a)',advance='no') "     Calculating body influences..."

        ! Calculate source and doublet influences from body
        do i=1,body%N_cp
            do j=1,body%N_panels

                ! Get source influence for existing->existing
                if (morino) then
                    source_inf = body%panels(j)%get_source_potential(body%control_points(i,:), this%freestream, &
                                                                     this%dod_info(j,i), source_verts, .false.)

                    ! Add influence for existing panel on existing control point
                    if (source_order == 0) then
                        body%phi_cp_sigma(i) = body%phi_cp_sigma(i) + source_inf(1)*body%sigma(j)
                    end if
                end if

                ! Get doublet influence for existing->existing
                doublet_inf = body%panels(j)%get_doublet_potential(body%control_points(i,:), this%freestream, &
                                                                   this%dod_info(j,i), doublet_verts, .false.)

                ! Add influence of existing panel on existing control point
                if (doublet_order == 1) then
                    do k=1,size(doublet_verts)
                        A(i,doublet_verts(k)) = A(i,doublet_verts(k)) + doublet_inf(k)
                    end do
                end if

                ! Get influences for mirroring
                if (body%mirrored) then

                    ! Influence of mirrored panels on mirrored control points for asymmetric flow
                    if (body%asym_flow .and. body%vertices(i)%mirrored_is_unique) then

                        ! Recalculate the mirrored->mirrored influences if the flow is compressible
                        if (.not. this%freestream%incompressible) then

                            ! Source influence
                            if (morino) then
                                source_inf = body%panels(j)%get_source_potential(body%cp_mirrored(i,:), this%freestream, &
                                                                                 this%dod_info(j+body%N_panels,i+body%N_cp), &
                                                                                 source_verts, .true.)
                            end if

                            ! Doublet influence
                            doublet_inf = body%panels(j)%get_doublet_potential(body%cp_mirrored(i,:), this%freestream, &
                                                                               this%dod_info(j+body%N_panels,i+body%N_cp), &
                                                                               doublet_verts, .true.)

                        end if

                        ! Add source influence
                        if (morino) then
                            if (source_order == 0) then
                                body%phi_cp_sigma(i+body%N_cp) = body%phi_cp_sigma(i+body%N_cp) &
                                                                 + source_inf(1)*body%sigma(j+body%N_panels)
                            end if
                        end if

                        ! Add doublet influence
                        if (doublet_order == 1) then
                            do k=1,size(doublet_verts)
                                A(i+body%N_cp,doublet_verts(k)+body%N_cp) = A(i+body%N_cp,doublet_verts(k)+body%N_cp) &
                                                                            + doublet_inf(k)
                            end do
                        end if

                    end if

                    ! Calculate existing->mirrored influences
                    if (morino) then
                        source_inf = body%panels(j)%get_source_potential(body%cp_mirrored(i,:), this%freestream, &
                                                                         this%dod_info(j,i+body%N_cp), source_verts, .false.)
                    end if
                    doublet_inf = body%panels(j)%get_doublet_potential(body%cp_mirrored(i,:), this%freestream, &
                                                                       this%dod_info(j,i+body%N_cp), doublet_verts, .false.)

                    if (body%asym_flow) then

                        ! Add influence of existing panel on mirrored control point
                        if (body%vertices(i)%mirrored_is_unique) then

                            if (morino) then
                                if (source_order == 0) then
                                    body%phi_cp_sigma(i+body%N_cp) = body%phi_cp_sigma(i+body%N_cp) + source_inf(1)*body%sigma(j)
                                end if
                            end if

                            if (doublet_order == 1) then
                                do k=1,size(doublet_verts)
                                    A(i+body%N_cp,doublet_verts(k)) = A(i+body%N_cp,doublet_verts(k)) + doublet_inf(k)
                                end do
                            end if

                        end if

                        ! Recalculate mirrored->existing influences for compressible flow
                        if (.not. this%freestream%incompressible) then

                            ! Source influence
                            if (morino) then
                                source_inf = body%panels(j)%get_source_potential(body%control_points(i,:), this%freestream, &
                                                                                 this%dod_info(j+body%N_panels,i), &
                                                                                 source_verts, .true.)
                            end if

                            ! Doublet influence
                            doublet_inf = body%panels(j)%get_doublet_potential(body%control_points(i,:), this%freestream, &
                                                                               this%dod_info(j+body%N_panels,i), &
                                                                               doublet_verts, .true.)

                        end if

                        ! Add influence of mirrored panel on existing control point
                        if (morino) then
                            if (source_order == 0) then
                                body%phi_cp_sigma(i) = body%phi_cp_sigma(i) + source_inf(1)*body%sigma(j+body%N_panels)
                            end if
                        end if

                        if (doublet_order == 1) then
                            do k=1,size(doublet_verts)
                                A(i,doublet_verts(k)+body%N_cp) = A(i,doublet_verts(k)+body%N_cp) + doublet_inf(k)
                            end do
                        end if

                    else

                        ! Influence of mirrored panel on existing control point
                        if (morino) then
                            if (source_order == 0) then
                                body%phi_cp_sigma(i) = body%phi_cp_sigma(i) + source_inf(1)*body%sigma(j)
                            end if
                        end if

                        if (doublet_order == 1) then
                            do k=1,size(doublet_verts)
                                A(i,doublet_verts(k)) = A(i,doublet_verts(k)) + doublet_inf(k)
                            end do
                        end if

                    end if

                end if

            end do

            ! Enforce doublet strength matching (i.e. for non-unique, mirrored control points, the
            ! doublet strengths must be the same). The RHS for these rows should still be zero.
            if (body%mirrored .and. body%asym_flow) then
                if (.not. body%vertices(i)%mirrored_is_unique) then
                    A(i+body%N_cp,i) = 1.
                    A(i+body%N_cp,i+body%N_cp) = -1.

                ! If the control point is unique, it's target potential will need to be set for the source-free formulation
                else if (.not. morino) then
                    b(i+body%N_cp) = inner(body%cp_mirrored(i,:), this%freestream%c0)
                end if
            end if

            ! Set target potential for source-free formulation
            if (.not. morino) then
                b(i) = inner(body%control_points(i,:), this%freestream%c0)
            end if

        end do
        write(*,*) "Done."

        ! Calculate influence of wake
        if (body%wake%N_panels > 0) then
            write(*,'(a)',advance='no') "     Calculating wake influences..."

            ! Loop through control points
            do i=1,body%N_cp

                ! Get doublet influence from wake
                ! Note that for the wake, in the case of mirrored mesh with asymmetric flow, the mirrored wake panels have actually been created.
                ! In this case, there are technically no mirrored panels, and this loop will cycle through both existing and mirrored panels.
                ! For symmetric flow, mirrored panels still need to be added as before.
                do j=1,body%wake%N_panels

                    ! Caclulate influence
                    doublet_inf = body%wake%panels(j)%get_doublet_potential(body%control_points(i,:), this%freestream, &
                                                                            this%dod_info(j,i), doublet_verts, .false.)

                    ! Influence on existing control point
                    if (doublet_order == 1) then
                        do k=1,size(doublet_verts)
                            A(i,doublet_verts(k)) = A(i,doublet_verts(k)) + doublet_inf(k)
                        end do
                    end if

                    ! Get influence on mirrored control point
                    if (body%mirrored) then

                        ! Calculate influences on mirrored point
                        doublet_inf = body%wake%panels(j)%get_doublet_potential(body%cp_mirrored(i,:), this%freestream, &
                                                                                this%dod_info(j,i), doublet_verts, .false.)

                        if (body%asym_flow) then

                            ! Influence on mirrored control point
                            if (body%vertices(i)%mirrored_is_unique) then
                                if (doublet_order == 1) then
                                    do k=1,size(doublet_verts)
                                        A(i+body%N_cp,doublet_verts(k)) = A(i+body%N_cp,doublet_verts(k)) + doublet_inf(k)
                                    end do
                                end if
                            end if

                        else

                            ! Influence of mirrored panel on existing control point
                            if (doublet_order == 1) then
                                do k=1,size(doublet_verts)
                                    A(i,doublet_verts(k)) = A(i,doublet_verts(k)) + doublet_inf(k)
                                end do
                            end if

                        end if

                    end if
                end do
            end do

            write(*,*) "Done."

        end if

        write(*,'(a)',advance='no') "     Solving linear system..."

        ! Make a copy of A (lu_solve replaces A with its decomposition)
        allocate(A_copy, source=A, stat=stat)
        call check_allocation(stat, "solver copy of AIC matrix")

        ! Set b vector for Morino formulation
        if (morino) then
            b = -body%phi_cp_sigma
        end if

        ! Solve
        call lu_solve(N_mu, A_copy, b, body%mu)
        write(*,*) "Done."

        ! Clean up memory
        deallocate(A_copy)

        ! Calculate potential at control points
        body%phi_cp_mu = matmul(A, body%mu)
        body%phi_cp = body%phi_cp_mu+body%phi_cp_sigma
        write(*,*) "        Maximum residual:", maxval(abs(body%phi_cp_mu-b))
        write(*,*) "        Norm of residual:", sqrt(sum((body%phi_cp_mu-b)**2))

        write(*,'(a)',advance='no') "     Calculating surface velocities and pressures..."

        ! Determine surface velocities
        if (body%mirrored .and. body%asym_flow) then

            ! Allocate velocity storage
            N_pressures = body%N_panels*2
            allocate(body%V(N_pressures,3), stat=stat)
            call check_allocation(stat, "surface velocity vectors")

            ! Calculate the surface velocity on each panel
            do i=1,body%N_panels

                if (morino) then

                    ! Original panel
                    body%V(i,:) = this%freestream%U*(-this%freestream%c0 + body%panels(i)%get_velocity_jump(body%mu, &
                                  body%sigma, .false., body%mirror_plane))

                    ! Mirror
                    body%V(i+body%N_panels,:) = this%freestream%U*(-this%freestream%c0 + body%panels(i)%get_velocity_jump(body%mu, &
                                                body%sigma, .true., body%mirror_plane))
                
                else

                    ! Original panel
                    body%V(i,:) = this%freestream%U*body%panels(i)%get_velocity_jump(body%mu, body%sigma, &
                                                                                     .false., body%mirror_plane)

                    ! Mirror
                    body%V(i+body%N_panels,:) = this%freestream%U*body%panels(i)%get_velocity_jump(body%mu, body%sigma, &
                                                                                              .true., body%mirror_plane)

                end if

            end do

        else

            ! Allocate velocity storage
            N_pressures = body%N_panels
            allocate(body%V(N_pressures,3), stat=stat)
            call check_allocation(stat, "surface velocity vectors")

            ! Calculate the surface velocity on each panel
            if (morino) then
                do i=1,body%N_panels
                    body%V(i,:) = this%freestream%U*(-this%freestream%c0 &
                                  + body%panels(i)%get_velocity_jump(body%mu, body%sigma, .false., 0))
                end do
            else
                do i=1,body%N_panels
                    body%V(i,:) = this%freestream%U*body%panels(i)%get_velocity_jump(body%mu, body%sigma, .false., 0)
                end do
            end if

        end if

        ! Calculate coefficients of pressure
        allocate(body%C_p(N_pressures), stat=stat)
        call check_allocation(stat, "surface pressures")
        do i=1,N_pressures
            body%C_p(i) = 1.-(norm(body%V(i,:))*this%freestream%U_inv)**2
        end do

        write(*,*) "Done."
        write(*,*) "        Maximum pressure coefficient:", maxval(body%C_p)
        write(*,*) "        Minimum pressure coefficient:", minval(body%C_p)

        ! Calculate total forces
        write(*,'(a)',advance='no') "     Calculating forces..."
        allocate(dC_F(N_pressures,3), stat=stat)
        call check_allocation(stat, "forces")
        do i=1,body%N_panels

            ! Discrete force coefficient acting on panel
            dC_F(i,:) = body%C_p(i)*body%panels(i)%A*body%panels(i)%normal

            ! Mirror
            if (body%mirrored .and. body%asym_flow) then
                n_mirrored = mirror_about_plane(body%panels(i)%normal, body%mirror_plane)
                dC_F(i+body%N_panels,:) = body%C_p(i+body%N_panels)*body%panels(i)%A*n_mirrored
            end if
        end do

        ! Sum discrete forces
        C_F(:) = sum(dC_F, dim=1)/body%S_ref

        write(*,*) "Done."
        write(*,*) "        Cx:", C_F(1)
        write(*,*) "        Cy:", C_F(2)
        write(*,*) "        Cz:", C_F(3)

        ! Write report file
        if (report_file /= 'none') then

            open(1, file=report_file)

            ! Header
            write(1,'(a)') "TriPan Report (c) 2021 USU AeroLab"

            ! Solver results
            write(1,*) "Maximum residual:", maxval(abs(body%phi_cp_mu-b))
            write(1,*) "Norm of residual:", sqrt(sum((body%phi_cp_mu-b)**2))
            write(1,*) "Maximum pressure coefficient:", maxval(body%C_p)
            write(1,*) "Minimum pressure coefficient:", minval(body%C_p)
            write(1,*) "Cx:", C_F(1)
            write(1,*) "Cy:", C_F(2)
            write(1,*) "Cz:", C_F(3)

            close(1)

        end if
    
    end subroutine panel_solver_solve_dirichlet


end module panel_solver_mod