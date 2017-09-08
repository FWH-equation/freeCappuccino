 !***********************************************************************
!
subroutine calcp
!***********************************************************************
!
! Assemble and solve pressure correction equation in SIMPLE algorithm
! Correct mass fluxes, presure and velocity field
! Enables multiple pressure corrections for non-orthogonal meshes
!
!***********************************************************************
!
  use types
  use parameters
  use geometry
  use sparse_matrix
  use variables
  use gradients
  use fieldManipulation
  use faceflux_mass

  implicit none

  include 'mpif.h'
!
!***********************************************************************
!

  integer :: i, k, inp, iface, ijp, ijn, iOtherProc, istage
  real(dp) :: sum, suma, ppref, cap, can, fmcor


  a = 0.0_dp
  apr = 0.0_dp
  su = 0.0_dp

  ! Tentative (!) velocity gradients used for velocity interpolation: 
  call grad(U,dUdxi)
  call grad(V,dVdxi)
  call grad(W,dWdxi)

  ! > Assemble off diagonal entries of system matrix and find mass flux at faces using Rhie-Chow interpolation

  ! Internal faces:
  do i = 1,numInnerFaces

    ijp = owner(i)
    ijn = neighbour(i)

    call facefluxmass(ijp, ijn, xf(i), yf(i), zf(i), arx(i), ary(i), arz(i), facint(i), cap, can, flmass(i))

    ! > Off-diagonal elements:

    ! (icell,jcell) matrix element:
    k = icell_jcell_csr_value_index(i)
    a(k) = can

    ! (jcell,icell) matrix element:
    k = jcell_icell_csr_value_index(i)
    a(k) = cap

    ! > Elements on main diagonal:

    ! (icell,icell) main diagonal element
    k = diag(ijp)
    a(k) = a(k) - can

    ! (jcell,jcell) main diagonal element
    k = diag(ijn)
    a(k) = a(k) - cap

    ! > Sources:

    su(ijp) = su(ijp) - flmass(i)
    su(ijn) = su(ijn) + flmass(i) 

  end do


  ! o- and c-grid cuts
  do i=1,noc

    iface= ijlFace(i) ! In the future implement Weiler-Atherton cliping algorithm to compute area vector components for non matching boundaries.
    ijp=ijl(i)
    ijn=ijr(i)

    call facefluxmass(ijp, ijn, xf(iface), yf(iface), zf(iface), arx(iface), ary(iface), arz(iface), foc(i), al(i), ar(i), fmoc(i))
    
    ! > Elements on main diagonal:

    ! (icell,icell) main diagonal element
    k = diag(ijp)
    a(k) = a(k) - ar(i)
    
    ! (jcell,jcell) main diagonal element
    k = diag(ijn)
    a(k) = a(k) - al(i)

    ! > Sources:

    su(ijp) = su(ijp) - fmoc(i)
    su(ijn) = su(ijn) + fmoc(i)

  end do


  ! Faces on processor boundary
  do i=1,npro

    iface = iProcFacesStart + i
    ijp = owner( iface )
    ijn = iProcStart + i

    call facefluxmass(ijp, ijn, xf(iface), yf(iface), zf(iface), arx(iface), ary(iface), arz(iface), fpro(i), cap, can, fmpro(i))

    ! > Off-diagonal elements:    
    apr(i) = can

    ! > Elements on main diagonal:

    ! (icell,icell) main diagonal element
    k = diag(ijp)
    a(k) = a(k) - can

    ! > Sources:

    su(ijp) = su(ijp) - fmpro(i)    

  end do

  !// adjusts the inlet and outlet fluxes to obey continuity, which is necessary for creating a well-posed
  !// problem where a solution for pressure exists.
  !     adjustPhi(phi, U, p);
  if(.not.const_mflux) call adjustMassFlow


  ! Test continutity:
  if(ltest) then
    suma = sum(su)
    call global_sum(suma)
    if (myid .eq. 0) write(6,'(19x,a,1pe10.3)') ' Initial sum  =',suma
  endif



!=====Multiple pressure corrections=====================================
  do ipcorr=1,npcor

    ! Initialize pressure correction
    pp=0.0d0

    ! Solving pressure correction equation
    ! call bicgstab(pp,ip) 
    call iccg(pp,ip)
    ! call dpcg(pp,ip)
    ! call gaussSeidel(pp,ip)
       
    ! SECOND STEP *** CORRECTOR STAGE
   
    do istage=1,nipgrad

      ! Pressure corr. at boundaries (for correct calculation of pp gradient)
      call bpres(pp,istage)

      ! Calculate pressure-correction gradient and store it in pressure gradient field.
      call grad(pp,dPdxi)
  
    end do

    ! Reference pressure correction - p'
    if (myid .eq. iPrefProcess) then

      ppref = pp(pRefCell)

      call MPI_BCAST(ppref,1,MPI_DOUBLE_PRECISION,iPrefProcess,MPI_COMM_WORLD,IERR)

    endif 


    !
    ! Correct mass fluxes at inner cv-faces only (only inner flux)
    !

    ! Inner faces:
    do iface=1,numInnerFaces

        ijp = owner(iface)
        ijn = neighbour(iface)

        ! (icell,jcell) matrix element:
        k = icell_jcell_csr_value_index(iface)

        flmass(iface) = flmass(iface) + a(k) * (pp(ijn)-pp(ijp))
  
    enddo

    ! Correct mass fluxes at faces along O-C grid cuts.
    do i=1,noc
        fmoc(i) = fmoc(i) + ar(i) * ( pp(ijr(i)) - pp(ijl(i)) )
    end do

    ! Correct mass fluxes at processor boundaries
    do i=1,npro 

        iface = iProcFacesStart + i
        ijp = owner(iface)
        iOtherProc = iProcStart + i

        fmpro(i) = fmpro(i) + apr(i) * ( pp( iOtherProc ) - pp( ijp ) )

    enddo


    !
    ! Correct velocities and pressure
    !      
    do inp=1,numCells

        u(inp) = u(inp) - apu(inp)*dPdxi(1,inp)*vol(inp)
        v(inp) = v(inp) - apv(inp)*dPdxi(2,inp)*vol(inp)
        w(inp) = w(inp) - apw(inp)*dPdxi(3,inp)*vol(inp)

        p(inp) = p(inp) + urf(ip)*(pp(inp)-ppref)

    enddo   

    ! Explicit correction of boundary conditions 
    call correctBoundaryConditionsVelocity

    !.......................................................................................................!
    if(ipcorr.ne.npcor) then      
    !                                    
    ! The source term for the non-orthogonal corrector, also the secondary mass flux correction.
    !

      ! Clean RHS vector
      su = 0.0d0

      do i=1,numInnerFaces                                                      
        ijp = owner(i)
        ijn = neighbour(i)

        call fluxmc(ijp, ijn, xf(i), yf(i), zf(i), arx(i), ary(i), arz(i), facint(i), fmcor)
        
        flmass(i) = flmass(i) + fmcor 

        su(ijp) = su(ijp) - fmcor
        su(ijn) = su(ijn) + fmcor   

      enddo                                                              

      ! Faces along O-C grid cuts
      do i=1,noc
        iface= ijlFace(i) ! In the future implement Weiler-Atherton cliping algorithm to compute area vector components for non matching boundaries.
        ijp = ijl(i)
        ijn = ijr(i)

        call fluxmc(ijp, ijn, xf(iface), yf(iface), zf(iface), arx(iface), ary(iface), arz(iface), foc(i), fmcor)
        
        fmoc(i) = fmoc(i) + fmcor

        su(ijp) = su(ijp) - fmcor
        su(ijn) = su(ijn) + fmcor
      end do


      ! Faces on processor boundary
      do i=1,npro
        iface = iProcFacesStart + i
        ijp = owner( iface )
        ijn = iProcStart + i

        call fluxmc(ijp, ijn, xf(iface), yf(iface), zf(iface), arx(iface), ary(iface), arz(iface), fpro(i), fmcor)
        
        fmpro(i) = fmpro(i) + fmcor
        
        su(ijp) = su(ijp) - fmcor
        su(ijn) = su(ijn) + fmcor

      end do

    
      ! ! Test continuity sum=0. The 'sum' should drop trough successive ipcorr corrections.
      ! if (myid .eq. 0) write(6,'(20x,i1,a,/,a,1pe10.3,1x,a,1pe10.3)')  &
      !                     ipcorr,'. nonorthogonal pass:', &
      !                                   ' sum  =',sum(su(:)),    &
      !                                   '|sum| =',abs(sum(su(:)))
                                                                                                 
    !.......................................................................................................!
    elseif(ipcorr.eq.npcor.and.npcor.gt.1) then 
    !
    ! Non-orthogonal mass flux corrector if we reached the end of non-orthogonal correction loop.
    ! Why not!
    !

      ! ! Correct mass fluxes at inner cv-faces with second corr.                                                      
      ! do i=1,numInnerFaces                                                      
      !   ijp = owner(i)
      !   ijn = neighbour(i)
      !   call fluxmc(ijp, ijn, xf(i), yf(i), zf(i), arx(i), ary(i), arz(i), facint(i), fmcor)
      !   flmass(i) = flmass(i)+fmcor                                                                                              
      ! enddo                                                             
                                                            
      !  ! Faces along O-C grid cuts
      ! do i=1,noc
      !   iface = iOCFacesStart+i
      !   call fluxmc(ijl(i), ijr(i), xf(iface), yf(iface), zf(iface), arx(iface), ary(iface), arz(iface), foc(i), fmcor)
      !   fmoc(i)=fmoc(i)+fmcor
      ! end do

    endif                                                             
    !.......................................................................................................!


!=END: Multiple pressure corrections loop==============================
  enddo

  call exchange( u )
  call exchange( v )
  call exchange( w )
  call exchange( p )

!.....Write continuity error report:
  include 'continuityErrors.h'

end subroutine
