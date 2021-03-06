program main

    use json_mod
    use json_xtnsn_mod
    use surface_mesh_mod
    use flow_mod
    use panel_solver_mod

    implicit none

    character(100) :: input_file
    character(len=:),allocatable :: body_file, wake_file, control_point_file, report_file

    type(json_file) :: input_json
    type(json_value), pointer :: flow_settings,&
                                 geometry_settings,&
                                 solver_settings,&
                                 output_settings
    type(surface_mesh) :: body_mesh
    type(flow) :: freestream_flow
    type(panel_solver) :: linear_solver

    ! Initialize developer things
    eval_count = 0

    ! Welcome message
    write(*,*) "           /"
    write(*,*) "          /"
    write(*,*) "         /"
    write(*,*) "        /          ____"
    write(*,*) "       /          /   /"
    write(*,*) "      /          /   /"
    write(*,*) "     /      TriPan (c) 2021 USU Aerolab"
    write(*,*) "    / _________/___/_______________"
    write(*,*) "   ( (__________________________"
    write(*,*) "    \          \   \"
    write(*,*) "     \          \   \"
    write(*,*) "      \          \   \"
    write(*,*) "       \          \___\"
    write(*,*) "        \"

    ! Set up run
    call json_initialize()

    ! Get input file from command line
    call getarg(1, input_file)

    ! Get input file from user
    if (input_file == '') then
        write(*,*) "Please specify an input file:"
        read(*,'(a)') input_file
        input_file = trim(input_file)
    end if

    ! Load settings from input file
    write(*,*) "Loading input file: ", input_file
    call input_json%load_file(filename=input_file)
    call json_check()
    call input_json%get('flow', flow_settings)
    call input_json%get('geometry', geometry_settings)
    call input_json%get('solver', solver_settings)
    call input_json%get('output', output_settings)

    ! Initialize surface mesh
    call body_mesh%init(geometry_settings)

    ! Initialize flow
    call freestream_flow%init(flow_settings)

    write(*,*)
    write(*,*) "Initializing"

    ! Perform flow-dependent initialization on the surface mesh
    call body_mesh%init_with_flow(freestream_flow)

    ! Initialize panel solver
    call linear_solver%init(solver_settings, body_mesh, freestream_flow)

    write(*,*)
    write(*,*) "Running solver using ", linear_solver%formulation, " formulation"

    ! Run solver
    call json_xtnsn_get(output_settings, 'report_file', report_file, 'none')
    call linear_solver%solve(body_mesh, report_file)

    ! Output results
    write(*,*)
    write(*,*) "Writing results to file"
    call json_xtnsn_get(output_settings, 'body_file', body_file, 'none')
    call json_xtnsn_get(output_settings, 'wake_file', wake_file, 'none')
    call json_xtnsn_get(output_settings, 'control_point_file', control_point_file, 'none')

    call body_mesh%output_results(body_file, wake_file, control_point_file)

    ! Goodbye
    write(*,*)
    write(*,*) "TriPan exited successfully."

end program main