!::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
!
!    This file is part of ICTP RegCM.
!
!    ICTP RegCM is free software: you can redistribute it and/or modify
!    it under the terms of the GNU General Public License as published by
!    the Free Software Foundation, either version 3 of the License, or
!    (at your option) any later version.
!
!    ICTP RegCM is distributed in the hope that it will be useful,
!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!    GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License
!    along with ICTP RegCM.  If not, see <http://www.gnu.org/licenses/>.
!
!::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

module mod_slabocean
  use mod_intkinds
  use mod_realkinds
  use mod_dynparam
  use mod_runparams
  use mod_memutil
  use mod_regcm_types
  use mod_atm_interface , only : xtsb
  use mod_mppparam
  use mod_constants
  use mod_stdio
  use mod_outvars

  implicit none

  private

  real(rkx) :: mlcp , dtocean

  ! the actual prognotic sst pointing on tg2
  real(rkx) , pointer , dimension(:,:) :: sstemp
  real(rkx) , pointer , dimension(:,:) :: ohfx , oqfx , ofsw , oflw
  real(rkx) , pointer , dimension(:,:,:) :: qflux_restore_sst
  real(rkx) , pointer , dimension (:,:) :: qflux_sst , qflux_adj , net_hflx , &
    hflx , qflb0 , qflb1 , qflbt
  logical , pointer , dimension(:,:) :: ocmask

  public :: allocate_mod_slabocean , init_slabocean , update_slabocean
  public :: fill_slaboc_outvars
  public :: qflb0 , qflb1 , qflbt , qflux_restore_sst

  contains
!
    subroutine allocate_mod_slabocean
      implicit none
      call getmem3d(qflux_restore_sst,jci1,jci2,ici1,ici2,1,mpy,&
                    'slab_ocean:qflux_restore_sst')
      call getmem2d(qflux_sst,jci1,jci2,ici1,ici2,'slab_ocean:qflux_sst')
      call getmem2d(qflux_adj,jci1,jci2,ici1,ici2,'slab_ocean:qflux_adj')
      call getmem2d(qflb0,jci1,jci2,ici1,ici2,'slab_ocean:qflb0')
      call getmem2d(qflb1,jci1,jci2,ici1,ici2,'slab_ocean:qflb1')
      call getmem2d(qflbt,jci1,jci2,ici1,ici2,'slab_ocean:qflbt')
      call getmem2d(net_hflx,jci1,jci2,ici1,ici2,'slab_ocean:net_hflx')
      call getmem2d(hflx,jci1,jci2,ici1,ici2,'slab_ocean:hflx')
      call getmem2d(ocmask,jci1,jci2,ici1,ici2,'slab_ocean:ocmask')
      stepcount(:) = 0
      dtocean = dtsrf
    end subroutine allocate_mod_slabocean
!
    subroutine init_slabocean(sfs,lndcat,fsw,flw)
      implicit none
      ! interface for regcm variable / slab ocean
      type(surfstate) , intent(in) :: sfs
      real(rkx) , pointer , intent(in) , dimension(:,:) :: lndcat
      real(rkx) , pointer , intent(in) , dimension(:,:) :: fsw , flw
      integer :: i , j

      ! water heat capacity ~ 4 J/g/K
      mlcp = mixed_layer_depth*4.0e6_rkx

      call assignpnt(sfs%tg,sstemp)
      call assignpnt(sfs%hfx,ohfx)
      call assignpnt(sfs%qfx,oqfx)
      call assignpnt(fsw,ofsw)
      call assignpnt(flw,oflw)
      do i = ici1 , ici2
        do j = jci1 , jci2
          if ( isocean(lndcat(j,i)) ) then
            ocmask(j,i) = .true.
          else
            ocmask(j,i) = .false.
          end if
        end do
      end do
    end subroutine init_slabocean

    subroutine update_slabocean(xt)
      implicit none
      real(rk8) , intent(in) :: xt
      ! mlcp is the heat capacity of the mixed layer [J / m3 / deg C] * m
      integer(ik4) :: i , j
#ifdef DEBUG
      real(rkx) , dimension(5) :: pval , pval1
#endif
      if ( do_restore_sst ) then
        stepcount(rcmtimer%month) = stepcount(rcmtimer%month)+1
        do i = ici1 , ici2
          do j = jci1 , jci2
            if ( ocmask(j,i) ) then
              qflux_sst(j,i) = (xtsb%b1(j,i) - sstemp(j,i)) * &
                mlcp / (sst_restore_timescale * 86400.0_rkx) ! w/m2
              qflux_restore_sst(j,i,rcmtimer%month) = &
                qflux_restore_sst(j,i,rcmtimer%month) + qflux_sst(j,i)
            end if
          end do
        end do
      else if ( do_qflux_adj ) then
        !
        ! Find the current climatological heat flux adjustment (qflux_adj).
        ! The qflux_adj can be added to the heat flux to find the net heat
        ! flux anomaly into the mixed layer for the coupled mixed layer expt.
        !
        ! Note that any ice model contributions need to be added in, which
        ! is handled in an off-line calculation to derive the final qflux
        ! adjustment. These include ice restoring and ice lid contributions.
        !
        qflux_adj = qflb0 + real(xt,rkx)*qflbt
      end if
      !
      ! energy budget in the mixed layer including the q flux therm
      !
#ifdef DEBUG
      if ( syncro_rep%will_act( ) ) then
        pval(1) = maxval(ofsw)
        pval(2) = maxval(oflw)
        pval(3) = maxval(ohfx)
        pval(4) = maxval(2.26e6_rkx*oqfx)
        pval(5) = maxval(qflux_adj)
        do i = 1 , size(pval)
          call maxall(pval(i),pval1(i))
        end do
        if ( myid == italk ) then
          write(stdout,'(a,f12.5)') ' $$$ SLAB :  max fsw = ', pval1(1)
          write(stdout,'(a,f12.5)') ' $$$         max flw = ', pval1(2)
          write(stdout,'(a,f12.5)') ' $$$         max hfx = ', pval1(3)
          write(stdout,'(a,f12.5)') ' $$$         max qfx = ', pval1(4)
          write(stdout,'(a,f12.5)') ' $$$         max adj = ', pval1(5)
        end if
      end if
#endif
      do i = ici1 , ici2
        do j = jci1 , jci2
          if ( ocmask(j,i) ) then
            ! The following are some key equations for this model:
            ! flux from or to the atmosphere ( convention = positive downward)
            ! multiply evaporation by latent heat of evaporation
            hflx(j,i) = ofsw(j,i)-oflw(j,i)-ohfx(j,i)-wlhv*oqfx(j,i)
            ! account for the retaured or adjustment flux term
            net_hflx(j,i) = hflx(j,i) + qflux_adj(j,i) + qflux_sst(j,i)
            ! update the prognostic seasurface temperature (pointing on tg2)
            sstemp(j,i) = sstemp(j,i) + dtocean*net_hflx(j,i)/mlcp
          end if
        end do
      end do
    end subroutine update_slabocean

    subroutine fill_slaboc_outvars
      implicit none
      integer(ik4) :: imon , i , j
      if ( associated(slab_qflx_out) ) then
        do imon = 1 , mpy
          if ( stepcount(imon) /= 0 ) then
            do i = ici1 , ici2
              do j = jci1 , jci2
                if ( ocmask(j,i) ) then
                  slab_qflx_out(j,i,imon) = &
                        qflux_restore_sst(j,i,imon)/real(stepcount(imon),rkx)
                else
                  slab_qflx_out(j,i,imon) = dmissval
                end if
              end do
            end do
          else
            do i = ici1 , ici2
              do j = jci1 , jci2
                if ( ocmask(j,i) ) then
                  slab_qflx_out(j,i,imon) = d_zero
                else
                  slab_qflx_out(j,i,imon) = dmissval
                end if
              end do
            end do
          end if
        end do
      end if
    end subroutine fill_slaboc_outvars
!
end module mod_slabocean
! vim: tabstop=8 expandtab shiftwidth=2 softtabstop=2
