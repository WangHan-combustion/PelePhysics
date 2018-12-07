module main_module

  use amrex_fort_module, only : amrex_real
  use mod_timers   

  implicit none

  real(amrex_real), dimension(:,:), allocatable :: Y_in, Y_forcing_in
  real(amrex_real), dimension(:), allocatable :: temp
  real(amrex_real) :: pressure
  integer :: nlin, cvode_iE, ivode

contains

    subroutine extern_init(name,namlen,cvode_meth,cvode_itmeth,cvode_iJac,cvode_iE_in,cvode_iDense_in,ivode_in) &
                    bind(C, name="extern_init")

    use, intrinsic :: iso_c_binding
    use network
    use eos_module
    use transport_module
    use reactor_module

    integer :: namlen
    integer :: name(namlen)
    integer(c_int), intent(in) :: cvode_meth
    integer(c_int), intent(in) :: cvode_itmeth
    integer(c_int), intent(in) :: cvode_iJac
    integer(c_int), intent(in) :: cvode_iE_in
    integer(c_int), intent(in) :: cvode_iDense_in
    integer(c_int), intent(in) :: ivode_in


    real (kind=dp_t) :: small_temp = 1.d-200
    real (kind=dp_t) :: small_dens = 1.d-200

    cvode_iE = cvode_iE_in
    ivode = ivode_in

    ! initialize the external runtime parameters in
    ! extern_probin_module
    call runtime_init(name,namlen)

    call network_init()

    call eos_init(small_temp, small_dens)

    call transport_init()

    if (ivode == 1) then
        ! cvode
        call reactor_init_cvode(cvode_meth, cvode_itmeth, cvode_iJac, cvode_iE, cvode_iDense_in)
    else
        call reactor_init(cvode_iE)
    end if

  end subroutine extern_init


  subroutine extern_close() bind(C, name="extern_close")

    use transport_module
    use reactor_module

    call transport_close()

    call reactor_close()

    !CALL t_total%stop

  end subroutine extern_close


  subroutine get_num_spec(nspec_out) bind(C, name="get_num_spec")

    use network, only : nspec

    implicit none

    integer, intent(out) :: nspec_out

    nspec_out = nspec

  end subroutine get_num_spec


  subroutine read_data_from_txt(name, namlen) &
          bind(C, name="read_data_from_txt")

    use network, only: nspec

    implicit none
    integer :: namlen
    integer :: name(namlen)
    ! Local var
    integer            :: i
    integer, parameter :: maxlen = 256
    character (len=maxlen) :: probin
    character(len=6)   :: a
    real(amrex_real)   :: y,x_velocity,y_velocity,density,dum

    ! create the filename
    if (namlen > maxlen) then
       print *, 'Initialization file name too long'
       stop
    endif
    do i = 1, namlen
       probin(i:i) = char(name(i))
    end do
    print *, "Initializing from output txt file ",probin(1:namlen)

    ! read in the file
    open (unit=49, file=probin(1:namlen), form='formatted', status='old')
    ! Start with number of useful lines
    read(49,*) nlin
    write(*,*) "  --> txt file has ", nlin, " lines"
    ! allocate stuff
    allocate(Y_in(nlin,nspec))
    allocate(Y_forcing_in(nlin,nspec+1))
    allocate(temp(nlin))
    ! ignore headers
    read(49,*) a
    read(49,*) a
    read(49,*) a
    ! read useful lines
    DO i = 1, nlin
      read(49,*) y, dum, y_velocity, density, dum, dum, temp(i), dum, dum, dum, dum, Y_in(i,:), dum, dum, dum, dum, dum, dum, Y_forcing_in(i,:)
      print *, sum(Y_in(i,:))
      !print *, Y_forcing_in(i,nspec+1)*10.0
    END DO
    ! Todo
    pressure = 1013250.d0

    close (unit=49)

    ! Conversion MKS to CGS for PelePhys
    !! nspec + 1 is energy which here is enthalpy !!
    DO i = 1, nlin
      Y_forcing_in(i,1:nspec) = Y_forcing_in(i,1:nspec)*1.d-3
      Y_forcing_in(i,nspec+1) = Y_forcing_in(i,nspec+1)*10.0
    END DO

  end subroutine read_data_from_txt


  subroutine initialize_data( &
       lo,           hi, &
       rhoY,         rY_lo, rY_hi, &
       rhoY_src,     rY_src_lo, rY_src_hi) &
       bind(C, name="initialize_data")

    use amrex_constants_module, only: M_PI, HALF, ONE, TWO, ZERO
    use network, only: nspec
    use eos_type_module
    use eos_module

    implicit none
    integer         , intent(in   ) ::     lo(3),    hi(3)
    integer         , intent(in   ) ::  rY_lo(3), rY_hi(3)
    integer         , intent(in   ) ::  rY_src_lo(3), rY_src_hi(3)
    real(amrex_real), intent(inout) ::  rhoY(rY_lo(1):rY_hi(1),rY_lo(2):rY_hi(2),rY_lo(3):rY_hi(3),nspec+2)
    real(amrex_real), intent(inout) ::  rhoY_src(rY_src_lo(1):rY_src_hi(1),rY_src_lo(2):rY_src_hi(2),rY_src_lo(3):rY_src_hi(3),nspec+1)

    ! local variables
    integer          :: i, j, k
    type(eos_t)      :: eos_state

    !CALL t_eos%start
    call build(eos_state)
    !CALL t_eos%stop

    ! CGS UNITS

    do k = lo(3),hi(3)
       do j = lo(2),hi(2)
          do i = lo(1),hi(1)

             eos_state % p          = pressure
             eos_state % T          = temp(i+1)
             eos_state % massfrac(:)     = Y_in(i+1,:)
             !eos_state % massfrac(nspec) = ONE - sum(Y_in(i+1,1:nspec-1))

             !CALL t_eos%start
             call eos_tp(eos_state)
             !CALL t_eos%stop

             ! rhoY(:nspec) = rhoY, rhoY(nspec+1) = nrg, rhoY(nspec+2) = T
             rhoY(i,j,k,1:nspec) = eos_state % massfrac * eos_state % rho
             if (cvode_iE == 1) then
                 ! all in e
                 !rhoY(i,j,k,nspec+1) = eos_state % e
                 write(*,*) "iE =  ", cvode_iE, " not implemented in 1D profile yet."
                 stop
             else
                 ! full enthalpy mode
                 rhoY(i,j,k,nspec+1) = eos_state % h
             end if
             rhoY(i,j,k,nspec+2) = eos_state % T

             ! rhoY_src(:nspec) = rhoForcingSpecs, rhoY_src(nspec+1) = rhoForcingNRG
             rhoY_src(i,j,k,1:nspec) = Y_forcing_in(i+1,1:nspec)
             rhoY_src(i,j,k,nspec+1) = Y_forcing_in(i+1,nspec+1)

          end do
       end do
    end do

    call destroy(eos_state)

  end subroutine initialize_data


  subroutine initialize_data_byhand( &
       lo,hi, &
       rhoY,         rY_lo, rY_hi) &
       bind(C, name="initialize_data_byhand")

    use amrex_constants_module, only: M_PI, HALF, ONE, TWO, ZERO
    use network, only: nspec
    use eos_type_module
    use eos_module

    implicit none

    integer         , intent(in   ) ::     lo(3),    hi(3)
    integer         , intent(in   ) ::  rY_lo(3), rY_hi(3)
    real(amrex_real), intent(inout) ::  rhoY(rY_lo(1):rY_hi(1),rY_lo(2):rY_hi(2),rY_lo(3):rY_hi(3),nspec+2)

    ! local variables
    integer           :: i, j, k, ii
    type(eos_t)       :: eos_state
    real(amrex_real)   :: dum
    real(amrex_real)   :: T_save, E_save, H_save, H_dup, E_dup
    character(len=6)   :: a

    !CALL t_eos%start
    call build(eos_state)
    !CALL t_eos%stop

    ! read in the file
    open (unit=49, file="datafromSC.dat", form='formatted', status='old')
    ! allocate stuff
    allocate(Y_in(1,nspec))
    allocate(temp(1))
    read(49,*) a
    print *,a
    read(49,*) pressure,temp(1),dum,Y_in(1,:)
    eos_state % molefrac(:) = Y_in(1,:)
    pressure = pressure*10.d0
    !print *, "data read from datafromSC.dat ", pressure,temp(1),eos_state % molefrac(:)
    print *, "sum mole frac ", sum(eos_state % molefrac(:))
    close (unit=49)

    !CALL t_eos%start
    call eos_xty(eos_state)
    !CALL t_eos%stop

    do k = lo(3),hi(3)
       do j = lo(2),hi(2)
          do i = lo(1),hi(1)

             eos_state % p               = pressure
             eos_state % T               = temp(1) 
             ! CAREFULL need to know N2 idx
             eos_state % massfrac(nspec) = ONE - sum(eos_state % massfrac(1:nspec-1))

             !CALL t_eos%start
             call eos_tp(eos_state)
             !CALL t_eos%stop

             rhoY(i,j,k,1:nspec) = eos_state % massfrac * eos_state % rho

             if (cvode_iE == 1) then
                 ! all in e
                 rhoY(i,j,k,nspec+1) = eos_state % e
             else
                 ! full enthalpy mode (HP reactor)
                 rhoY(i,j,k,nspec+1) = eos_state % h
             end if
             rhoY(i,j,k,nspec+2) = eos_state % T

          end do
       end do
    end do

    call destroy(eos_state)
    deallocate(Y_in)
    deallocate(temp)

  end subroutine initialize_data_byhand


  subroutine react_state(lo,hi, &
                         mold,mo_lo,mo_hi, &
                         mnew,mn_lo,mn_hi, &
                         ysrc,ys_lo,ys_hi, &
                         mask,m_lo,m_hi, &
                         cost,c_lo,c_hi, &
                         time,ndt,dt_react) bind(C, name="react_state")

    use network           , only : nspec
    use react_type_module
    use reactor_module
    use react_type_module
    use, intrinsic :: iso_c_binding

    implicit none

    integer         , intent(in   ) ::    lo(3),    hi(3)
    integer         , intent(in   ) :: mo_lo(3), mo_hi(3)
    integer         , intent(in   ) :: mn_lo(3), mn_hi(3)
    integer         , intent(in   ) :: ys_lo(3), ys_hi(3)
    integer         , intent(in   ) ::  m_lo(3),  m_hi(3)
    integer         , intent(in   ) ::  c_lo(3),  c_hi(3)
    real(amrex_real), intent(inout)  :: mold(mo_lo(1):mo_hi(1),mo_lo(2):mo_hi(2),mo_lo(3):mo_hi(3),nspec+2)
    real(amrex_real), intent(inout)  :: mnew(mn_lo(1):mn_hi(1),mn_lo(2):mn_hi(2),mn_lo(3):mn_hi(3),nspec+2)
    real(amrex_real), intent(inout)  :: ysrc(ys_lo(1):ys_hi(1),ys_lo(2):ys_hi(2),ys_lo(3):ys_hi(3),nspec+1)
    integer, intent(inout)           :: mask(m_lo(1):m_hi(1),m_lo(2):m_hi(2),m_lo(3):m_hi(3))
    real(amrex_real), intent(inout)  :: cost(c_lo(1):c_hi(1),c_lo(2):c_hi(2),c_lo(3):c_hi(3))
    real(c_double), intent(in)       :: time, dt_react
    integer         , intent(in   ) ::  ndt

    ! local variables
    integer          :: i, j, k, ii
    real(amrex_real) :: rho
    integer          :: istop 
    real(c_double)   :: dt_react_tmp, dt_react_incr, time_tmp

    type (react_t)          :: react_state_in !, react_state_out
    type (reaction_stat_t)  :: stat

    call build(react_state_in)

    istop = 0
    do k = lo(3), hi(3)
       do j = lo(2), hi(2)
          do i = lo(1), hi(1)

                write(*,*) ""
                write(*,*) "Dealing with cell ", i,j,k

                if (cvode_iE == 1) then
                    react_state_in %              e = mold(i,j,k,nspec+1)
                    react_state_in %    rhoedot_ext = ysrc(i,j,k,nspec+1)
                else if ((cvode_iE == 2).or.(cvode_iE == 5)) then
                    react_state_in %              h = mold(i,j,k,nspec+1)
                    react_state_in %    rhohdot_ext = ysrc(i,j,k,nspec+1)
                else
                    write(*,*) "iE =  ", cvode_iE, " not implemented yet."
                    stop
                end if
                react_state_in %              T = mold(i,j,k,nspec+2)
                react_state_in %        rhoY(:) = mold(i,j,k,1:nspec)
                react_state_in %            rho = sum(react_state_in % rhoY(:))
                react_state_in %              p = pressure
                react_state_in % rhoYdot_ext(:) = ysrc(i,j,k,1:nspec)

                react_state_in % i = i
                react_state_in % j = j
                react_state_in % k = k

                if (ivode == 1) then
                    ! cvode
                    time_tmp = time
                    dt_react_incr =  dt_react
                    write(12,*) "#CVODE "
                    write(12,*) "#time, T, e, h, P, rho, Yks "
                    do ii= 1, ndt
                        !write(*,*) " "
                        !write(*,*) "#dt_react_incr ", dt_react_incr
                        dt_react_tmp   = ii* dt_react_incr
                        stat = react_cvode(react_state_in, react_state_in, dt_react_incr, time)
                        time_tmp       = dt_react_tmp
                        rho            = sum(react_state_in % rhoY(1:nspec))
                        write(12,*) time_tmp, react_state_in % T, react_state_in %e, react_state_in %h, react_state_in % p, react_state_in %rho, react_state_in % rhoY(1:nspec)/rho
                    end do
                else 
                    time_tmp = time
                    dt_react_incr =  dt_react
                    write(12,*) "#DVODE "
                    write(12,*) "#dt_react_incr ", dt_react_incr
                    write(12,*) "#time, T, e, h, P, rho, Yks "
                    do ii= 1, ndt
                        dt_react_tmp   = ii* dt_react_incr
                        stat = react(react_state_in, react_state_in, dt_react_incr, time)
                        time_tmp       = dt_react_tmp
                        rho            = sum(react_state_in % rhoY(1:nspec))
                        write(12,*) time_tmp, react_state_in % T, react_state_in %e, react_state_in %h, react_state_in % p, react_state_in %rho, react_state_in % rhoY(1:nspec)/rho
                    end do
                end if
                cost(i,j,k) = stat % cost_value

                ! Export e whenever
                mnew(i,j,k,nspec+1)             = react_state_in % e
                mnew(i,j,k,nspec+2)             = react_state_in % T
                mnew(i,j,k,1:nspec)             = react_state_in % rhoY(1:nspec)
                rho                             = sum(mnew(i,j,k,1:nspec))
                mnew(i,j,k,1:nspec)             = mnew(i,j,k,1:nspec)/rho
          end do
       enddo
    enddo

    !CALL t_total%stop
    !CALL t_total%norm(t_total)
    !CALL t_eos%norm(t_total)
    !CALL t_ck%norm(t_total)
    !!CALL t_init%norm(t_total)
    !CALL t_ReInit%norm(t_total)
    !CALL t_CVODE%norm(t_total)
    !CALL t_AJac%norm(t_CVODE)
    !CALL t_ckJac%norm(t_AJac)
    !!PRINTS
    !CALL t_total%print
    !CALL t_eos%print
    !CALL t_ck%print
    !!CALL t_init%print
    !CALL t_ReInit%print
    !CALL t_CVODE%print
    !CALL t_AJac%print
    !CALL t_ckJac%print
    !!RESETS
    !CALL t_total%reset
    !CALL t_eos%reset
    !CALL t_ck%reset
    !CALL t_CVODE%reset
    !CALL t_ReInit%reset
    !CALL t_AJac%reset
    !CALL t_ckJac%reset

    !CALL t_total%start


    call destroy(react_state_in)

  end subroutine react_state



end module main_module