! Subroutines for I/O with VTK files
module vtk_mod

    use panel_mod
    use vertex_mod

    implicit none

    type vtk_out

        character(len=:),allocatable :: filename
        integer :: unit
        logical :: cell_data_begun, point_data_begun

        contains

            procedure :: begin => vtk_out_begin
            procedure :: vtk_out_write_points_vertices
            procedure :: vtk_out_write_points_array
            generic :: write_points => vtk_out_write_points_vertices, vtk_out_write_points_array
            procedure :: write_panels => vtk_out_write_panels
            procedure :: write_vertices => vtk_out_write_vertices
            procedure :: write_point_scalars => vtk_out_write_point_scalars
            procedure :: write_cell_scalars => vtk_out_write_cell_scalars
            procedure :: write_point_vectors => vtk_out_write_point_vectors
            procedure :: write_cell_vectors => vtk_out_write_cell_vectors
            procedure :: finish => vtk_out_finish

    end type vtk_out

    
contains


    subroutine vtk_out_begin(this, filename)
        ! Starts writing out a vtk file

        implicit none

        class(vtk_out),intent(inout) :: this
        character(len=:),allocatable,intent(in) :: filename

        logical :: is_open

        ! Store filename
        this%filename = filename

        ! Check if file is opened already
        inquire(file=this%filename, opened=is_open)
        if (is_open) then
            write(*,*) "Cannot write to ", this%filename, ". Already opened."
        end if

        ! Find an available unit
        is_open = .true.
        this%unit = 0
        do while (is_open)

            ! Update unit number
            this%unit = this%unit + 1

            ! Check if it is open
            inquire(unit=this%unit, opened=is_open)

        end do

        ! Open file
        open(this%unit, file=this%filename)

        ! Write header
        write(this%unit,'(a)') "# vtk DataFile Version 3.0"
        write(this%unit,'(a)') "TriPan results file. Generated by TriPan, USU AeroLab (c) 2021."
        write(this%unit,'(a)') "ASCII"

        ! Initialize a few checks
        this%cell_data_begun = .false.
        this%point_data_begun = .false.
    
    end subroutine vtk_out_begin


    subroutine vtk_out_write_points_vertices(this, vertices)
        ! Writes out points to the vtk file using the TriPan vertex object

        implicit none

        class(vtk_out),intent(in) :: this
        type(vertex),dimension(:),intent(in) :: vertices

        integer :: i, N_verts

        ! Write vertex information
        N_verts = size(vertices)
        write(this%unit,'(a)') "DATASET POLYDATA"
        write(this%unit,'(a i20 a)') "POINTS", N_verts, " float"

        ! Write out vertices
        do i=1,N_verts
            write(this%unit,'(e20.12, e20.12, e20.12)') vertices(i)%loc(1), vertices(i)%loc(2), vertices(i)%loc(3)
        end do
    
    end subroutine vtk_out_write_points_vertices


    subroutine vtk_out_write_points_array(this, vertices)
        ! Writes out points to the vtk file using a simple array of locations

        implicit none

        class(vtk_out),intent(in) :: this
        real,dimension(:,:),intent(in) :: vertices

        integer :: i, N_verts

        ! Write vertex information
        N_verts = size(vertices)/3
        write(this%unit,'(a)') "DATASET POLYDATA"
        write(this%unit,'(a i20 a)') "POINTS", N_verts, " float"

        ! Write out vertices
        do i=1,N_verts
            write(this%unit,'(e20.12, e20.12, e20.12)') vertices(i,1), vertices(i,2), vertices(i,3)
        end do
    
    end subroutine vtk_out_write_points_array


    subroutine vtk_out_write_panels(this, panels)
        ! Write out panels to the vtk file

        implicit none

        class(vtk_out),intent(in) :: this
        type(panel),dimension(:),intent(in) :: panels

        integer :: i, j, N_panels, panel_info_size

        ! Determine panel info size
        panel_info_size = 0
        N_panels = size(panels)
        do i=1,N_panels
            panel_info_size = panel_info_size + panels(i)%N + 1
        end do
        
        ! Write out panels
        write(this%unit,'(a i20 i20)') "POLYGONS", N_panels, panel_info_size
        do i=1,N_panels

            ! Number of vertices
            write(this%unit,'(i1) ',advance='no') panels(i)%N

            ! Indices of each vertex
            do j=1,panels(i)%N
                write(this%unit,'(i20) ',advance='no') panels(i)%vertices(j)%ptr%index-1
            end do
            
            ! Move to next line
            write(this%unit,*)

        end do
    
    end subroutine vtk_out_write_panels


    subroutine vtk_out_write_vertices(this, vertices)
        ! Writes vertices (VTK vertices, which are different than points) to the file

        implicit none

        class(vtk_out),intent(in) :: this
        real,dimension(:,:),intent(in) :: vertices

        integer :: i, N_verts

        ! Write out vertices
        N_verts = size(vertices)/3
        write(1,'(a i20 i20)') "VERTICES", N_verts, N_verts*2
        do i=1,N_verts

            ! Index of each vertex
            write(1,'(i1 i20)') 1, i-1

        end do
    
    end subroutine vtk_out_write_vertices


    subroutine vtk_out_write_cell_scalars(this, data, label)
        ! Writes out cell scalar data

        implicit none

        class(vtk_out),intent(inout) :: this
        real,dimension(:),intent(in) :: data
        character(len=*),intent(in) :: label

        integer :: N_cells, i

        ! Write cell data header
        N_cells = size(data)
        if (.not. this%cell_data_begun) then
            
            ! Write out header
            write(this%unit,'(a i20)') "CELL_DATA", N_cells

            ! Set toggle that header has already been written
            this%cell_data_begun = .true.

        end if

        ! Write data
        write(this%unit,'(a, a, a)') "SCALARS ", label, " float 1"
        write(this%unit,'(a)') "LOOKUP_TABLE default"
        do i=1,N_cells
            write(this%unit,'(e20.12)') data(i)
        end do
    
    end subroutine vtk_out_write_cell_scalars


    subroutine vtk_out_write_cell_vectors(this, data, label)
        ! Writes out cell vector data

        implicit none

        class(vtk_out),intent(inout) :: this
        real,dimension(:,:),intent(in) :: data
        character(len=*),intent(in) :: label

        integer :: N_cells, i

        ! Write cell data header
        N_cells = size(data)/3
        if (.not. this%cell_data_begun) then
            
            ! Write out header
            write(this%unit,'(a i20)') "CELL_DATA", N_cells

            ! Set toggle that header has already been written
            this%cell_data_begun = .true.

        end if

        ! Write vectors
        write(1,'(a, a, a)') "VECTORS ", label, " float"
        do i=1,N_cells
            write(1,'(e20.12, e20.12, e20.12)') data(i,1), data(i,2), data(i,3)
        end do
    
    end subroutine vtk_out_write_cell_vectors


    subroutine vtk_out_write_point_scalars(this, data, label)
        ! Writes out point scalar data

        implicit none

        class(vtk_out),intent(inout) :: this
        real,dimension(:),intent(in) :: data
        character(len=*),intent(in) :: label

        integer :: i, N_points

        ! Write point data header
        N_points = size(data)
        if (.not. this%point_data_begun) then
            
            ! Write out header
            write(this%unit,'(a i20)') "POINT_DATA", N_points

            ! Set toggle that header has already been written
            this%point_data_begun = .true.

        end if

        ! Write data
        write(1,'(a, a, a)') "SCALARS ", label, " float 1"
        write(1,'(a)') "LOOKUP_TABLE default"
        do i=1,N_points
            write(1,'(e20.12)') data(i)
        end do
    
    end subroutine vtk_out_write_point_scalars


    subroutine vtk_out_write_point_vectors(this, data)
        ! Writes out point vector data

        implicit none

        class(vtk_out),intent(inout) :: this
        real,dimension(:,:),intent(in) :: data
    
    end subroutine vtk_out_write_point_vectors
    

    subroutine vtk_out_finish(this)
        ! Closes the file

        implicit none

        class(vtk_out),intent(in) :: this

        ! Close the file
        close(this%unit)
    
    end subroutine vtk_out_finish


    subroutine write_surface_vtk(output_file, vertices, panels, sigma, mu, is_wake, vel, C_p)
        ! OBSOLETE

        implicit none

        character(len=:),allocatable,intent(in) :: output_file
        type(vertex),dimension(:),intent(in) :: vertices
        type(panel),dimension(:),intent(in) :: panels
        real,dimension(:),allocatable,optional,intent(in) :: sigma, mu, C_p
        real,dimension(:,:),allocatable,optional,intent(in) :: vel
        logical,optional :: is_wake
        integer :: i, N_verts, N_panels, panel_info_size, j

        ! Open file
        open(1, file=output_file)

            ! Write header
            write(1,'(a)') "# vtk DataFile Version 3.0"
            write(1,'(a)') "TriPan results file. Generated by TriPan, USU AeroLab (c) 2021."
            write(1,'(a)') "ASCII"

            ! Write vertex information
            N_verts = size(vertices)
            write(1,'(a)') "DATASET POLYDATA"
            write(1,'(a i20 a)') "POINTS", N_verts, " float"

            ! Write out vertices
            100 format(e20.12, ' ', e20.12, ' ', e20.12) ! Vertices
            do i=1,N_verts
                write(1,100) vertices(i)%loc(1), vertices(i)%loc(2), vertices(i)%loc(3)
            end do

            ! Determine panel info size
            panel_info_size = 0
            N_panels = size(panels)
            do i=1,N_panels
                panel_info_size = panel_info_size + panels(i)%N + 1
            end do
            
            ! Write out panels
            write(1,'(a i20 i20)') "POLYGONS", N_panels, panel_info_size
            do i=1,N_panels

                ! Number of vertices
                write(1,'(i1) ',advance='no') panels(i)%N

                ! Indices of each vertex
                do j=1,panels(i)%N
                    write(1,'(i20) ',advance='no') panels(i)%vertices(j)%ptr%index-1
                end do
                write(1,*)

            end do

            ! Write out panel normals
            write(1,'(a i20)') "CELL_DATA", N_panels
            write(1,'(a)') "NORMALS panel_normals float"
            do i=1,N_panels
                write(1,100) panels(i)%normal(1), panels(i)%normal(2), panels(i)%normal(3)
            end do

            ! Indices
            write(1,'(a)') "SCALARS index integer 1"
            write(1,'(a)') "LOOKUP_TABLE default"
            do i=1,N_panels
                write(1,'(i20)') i
            end do

            ! Check if this is a wake mesh
            if (present(is_wake) .and. is_wake) then

                ! Panel source strengths
                if (present(sigma)) then
                    write(1,'(a)') "SCALARS sigma float 1"
                    write(1,'(a)') "LOOKUP_TABLE default"
                    do i=1,N_panels
                        write(1,'(e20.12)') 0.
                    end do
                end if

                ! Vertex doublet strengths
                if (present(mu)) then
                    write(1, '(a i20)') "POINT_DATA", N_verts
                    write(1,'(a)') "SCALARS mu float 1"
                    write(1,'(a)') "LOOKUP_TABLE default"
                    do i=1,N_verts
                        write(1,'(e20.12)') mu(vertices(i)%top_parent)-mu(vertices(i)%bot_parent)
                    end do
                end if

            ! Regular body mesh
            else

                ! Panel source strengths
                if (present(sigma)) then
                    write(1,'(a)') "SCALARS sigma float 1"
                    write(1,'(a)') "LOOKUP_TABLE default"
                    do i=1,N_panels
                        write(1,'(e20.12)') sigma(i)
                    end do
                end if

                ! Panel velocities
                if (present(vel)) then
                    write(1,'(a)') "VECTORS V float"
                    do i=1,N_panels
                        write(1,100) vel(i,1), vel(i,2), vel(i,3)
                    end do
                end if

                ! Panel pressure coefficients
                if (present(C_p)) then
                    write(1,'(a)') "SCALARS C_p float 1"
                    write(1,'(a)') "LOOKUP_TABLE default"
                    do i=1,N_panels
                        write(1,'(e20.12)') C_p(i)
                    end do
                end if

                ! Vertex doublet strengths
                if (present(mu)) then
                    write(1, '(a i20)') "POINT_DATA", N_verts
                    write(1,'(a)') "SCALARS mu float 1"
                    write(1,'(a)') "LOOKUP_TABLE default"
                    do i=1,N_verts
                        write(1,'(e20.12)') mu(i)
                    end do
                end if

            end if

        close(1)
    
    end subroutine write_surface_vtk


    subroutine write_point_vtk(output_file, points, phi, phi_mu, phi_sigma)

        implicit none

        character(len=:),allocatable,intent(in) :: output_file
        real,dimension(:,:),intent(in) :: points
        real,dimension(:),intent(in) :: phi, phi_mu, phi_sigma
        integer :: i, N_verts, vertex_info_size

        ! Open file
        open(1, file=output_file)

            ! Write header
            write(1,'(a)') "# vtk DataFile Version 3.0"
            write(1,'(a)') "TriPan results file. Generated by TriPan, USU AeroLab (c) 2021."
            write(1,'(a)') "ASCII"

            ! Write point information
            N_verts = size(points)/3
            write(1,'(a)') "DATASET POLYDATA"
            write(1,'(a i20 a)') "POINTS", N_verts, " float"

            ! Write out points
            100 format(e20.12, ' ', e20.12, ' ', e20.12) ! Vertices
            do i=1,N_verts
                write(1,100) points(i,1), points(i,2), points(i,3)
            end do

            ! Determine vertex info size
            vertex_info_size = 2*N_verts
            
            ! Write out panels
            write(1,'(a i20 i20)') "VERTICES", N_verts, vertex_info_size
            do i=1,N_verts

                ! Number of vertices
                write(1,'(i1) ',advance='no') 1

                ! Index of each vertex
                write(1,'(i20)') i-1

            end do

            ! Potential at points
            write(1, '(a i20)') "POINT_DATA", N_verts
            write(1,'(a)') "SCALARS phi float 1"
            write(1,'(a)') "LOOKUP_TABLE default"
            do i=1,N_verts
                write(1,'(e20.12)') phi(i)
            end do

            ! Potential at points due to doublet distribution
            write(1,'(a)') "SCALARS phi_mu float 1"
            write(1,'(a)') "LOOKUP_TABLE default"
            do i=1,N_verts
                write(1,'(e20.12)') phi_mu(i)
            end do

            ! Potential at points due to source distribution
            write(1,'(a)') "SCALARS phi_sigma float 1"
            write(1,'(a)') "LOOKUP_TABLE default"
            do i=1,N_verts
                write(1,'(e20.12)') phi_sigma(i)
            end do

            ! Indices
            write(1,'(a)') "SCALARS index integer 1"
            write(1,'(a)') "LOOKUP_TABLE default"
            do i=1,N_verts
                write(1,'(i20)') i
            end do

        close(1)
        
    
    end subroutine write_point_vtk


    subroutine load_surface_vtk(mesh_file, N_verts, N_panels, vertices, panels)
        ! Loads a surface mesh from a vtk file. Only a body.
        ! Needs to be updated to automatically delete duplicate vertices.

        implicit none

        character(len=:),allocatable,intent(in) :: mesh_file
        integer,intent(out) :: N_verts, N_panels
        character(len=200) :: dummy_read
        type(vertex),dimension(:),allocatable,intent(inout) :: vertices
        type(panel),dimension(:),allocatable,intent(inout) :: panels
        real,dimension(3) :: vertex_loc
        integer :: i, j, N, i1, i2, i3, i4

        ! Open file
        open(1, file=mesh_file)

            ! Determine number of vertices
            read(1,*) ! Header
            read(1,*) ! Header
            read(1,*) ! Header
            read(1,*) ! Header
            read(1,*) dummy_read, N_verts, dummy_read

            ! Allocate vertex array
            allocate(vertices(N_verts))

            ! Store vertices
            do i=1,N_verts

                ! Read in from file
                read(1,*) vertex_loc(1), vertex_loc(2), vertex_loc(3)

                ! Initialize
                call vertices(i)%init(vertex_loc, i)

            end do

            ! Determine number of panels
            read(1,*) dummy_read, N_panels, dummy_read

            ! Allocate panel array
            allocate(panels(N_panels))

            ! Initialize panels
            do i=1,N_panels

                ! Get data
                read(1,'(a)') dummy_read
                
                ! Determine size of panel
                if (dummy_read(1:2) == '3 ') then
                    read(dummy_read,*) N, i1, i2, i3
                else
                    write(*,*) "TriPan supports only triangular panels."
                    stop
                end if

                ! Initialize triangular panel
                if (N == 3) then
                    call panels(i)%init(vertices(i1+1), vertices(i2+1), vertices(i3+1),&
                                        i1+1, i2+1, i3+1, i) ! Need +1 because VTK uses 0-based indexing

                    ! Add panel index to vertices
                    call vertices(i1+1)%panels%append(i)
                    call vertices(i2+1)%panels%append(i)
                    call vertices(i3+1)%panels%append(i)
                end if

            end do

        close(1)
    
    end subroutine load_surface_vtk

    
end module vtk_mod