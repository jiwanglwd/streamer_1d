!> Module with generic functionality for particle and fluid models, in
!> particular a description of the domain and routines to compute the electric
!> field.
module m_generic

  implicit none
  private

  integer, parameter :: dp = kind(0.0d0)

  integer, parameter, public :: model_particle  = 1
  integer, parameter, public :: model_fluid_lfa = 2
  integer, parameter, public :: model_fluid_ee  = 3
  integer, protected, public :: model_type      = 2

  real(dp), protected, public :: domain_length = 1.0e-3_dp
  integer, protected, public  :: domain_ncell  = 500
  real(dp), protected, public :: domain_dx     = 2e-6_dp
  real(dp), protected, public :: domain_inv_dx = 5e5_dp

  !> Whether a dielectric is present on the left
  logical, protected, public :: left_dielectric_present = .false.

  !> The boundary coordinate of the left dielectric
  real(dp), protected, public :: left_dielectric_x = -1.0_dp

  !> Relative permittivity of the left dielectric
  real(dp), protected, public :: left_dielectric_eps = 1.0_dp

  !> Cell face index of the dielectric boundary, where 1 is at 0.0
  integer, protected, public :: left_dielectric_iface = -1

  !> Electric field at cell centers
  real(dp), allocatable :: field_cc(:)

  !> Electric field at cell faces
  real(dp), allocatable :: field_fc(:)

  integer, parameter :: init_gaussian_type = 1
  integer, parameter :: init_block_type    = 2

  !> Type of initial condition (init_gaussian_type, init_block_type)
  real(dp)            :: init_type

  !> Initial condition location
  real(dp)            :: init_location

  !> Initial condition width
  real(dp)            :: init_width

  !> Initial condition charge type (1: positive ions, -1: electrons, 0: neutral)
  real(dp)            :: init_charge_type

  !> Initial condition density
  real(dp)            :: init_density

  public :: generic_initialize
  public :: compute_field
  public :: get_field_at
  ! public :: field_emission
  ! public :: pot_left
  ! public :: work_fun

contains

  subroutine generic_initialize(cfg)
    use m_config
    type(CFG_t), intent(in) :: cfg

    call CFG_add_get(cfg, "domain%length", domain_length)
    call CFG_add_get(cfg, "domain%n_cell", domain_ncell)

    domain_dx        = domain_length / domain_ncell
    domain_inv_dx    = 1/dx

    call CFG_add_get(cfg, "model_type", model_type_name)

    select case (model_type_name)
    case ("part", "particle")
       model_type = model_particle
    case ("fluid_lfa")
       model_type = model_fluid_lfa
    case ("fluid_ee")
       model_type = model_fluid_ee
    case default
       print *, "Invalid simulation type given: ", MODEL_type_name
       print *, "Supported are: particle, fluid_lfa, fluid_ee"
       error stop "Invalid simulation type"
    end select

    allocate(field_cc(domain_ncell))
    field_cc(:) = 0.0_dp

    ! Field at cell faces includes one extra point
    allocate(field_fc(domain_ncell+1))
    field_fc(:) = 0.0_dp

    ! field_cc(1) is centered at x = 0.5 dx
    ! field_fc(1) is centered at x = 0.0 dx

    call CFG_add_get(cfg, "left_dielectric_x", left_dielectric_x)
    call CFG_add_get(cfg, "left_dielectric_eps", left_dielectric_eps)

    left_dielectric_present = (&
         left_dielectric_x >= 0.0_dp .and. &
         left_dielectric_x < domain_length .and. &
         abs(left_dielectric_eps - 1.0_dp) > 0.0_dp)

    if (left_dielectric_present) then
       left_dielectric_iface = nint(left_dielectric_x / domain_dx) + 1
       left_dielectric_x = (left_dielectric_iface-1) * domain_dx
    end if

    call CFG_add_get(cfg, "init%type", init_type_name)

    select case (init_type_name)
    case ("block"
       init_cond_type = init_block_type
    case ("gaussian", "Gaussian")
       init_cond_type = init_gaussian_type
    end select

  end subroutine generic_initialize

  subroutine compute_field(net_charge, left_surface_charge, time)
    use m_units_constants
    real(dp), intent(in) :: net_charge(:), left_surface_charge, time
    real(dp)             :: conv_fac, E_corr_gas, E_corr_eps, E_corr_homog
    real(dp)             :: pot_diff, dielectric_field
    integer              :: iz

    if (size(net_charge) /= domain_ncell) &
         error stop "compute_field: argument has wrong size"
    if (.not. left_dielectric_present) &
         error stop "compute_field: no dielectric present"

    ! First we start from a guess field_fc(1) = 0, which is the electric field
    ! at the left domain boundary. Inside the dielectric, the field is constant.
    field_fc(1:left_dielectric_iface-1) = 0.0_dp

    ! Note that on the dielectric boundary, the electric field is different on
    ! both sides, but we only store the value outside the dielectric for now.
    field_fc(left_dielectric_iface) = left_surface_charge / (UC_eps0 * eps_DI)

    ! Handle the region outside the dielectric
    conv_fac = domain_dx / UC_eps0
    do iz = left_dielectric_iface+1, domain_ncell+1
       field_fc(iz) = field_fc(iz-1) + net_charge(iz-1) * conv_fac
    end do

    ! Compute total potential difference. Here we assign a weight of 0.5 to the
    ! boundary values (on the dielectric and the wall)
    pot_diff = domain_dx * (sum(field_fc(left_dielectric_iface+1:domain_ncell)) + &
         0.5_dp * (field_fc(left_dielectric_iface) + field_fc(domain_ncell+1)))

    ! Have to correct the potential by this amount
    pot_correct = pot_diff - get_potential(time)

    ! Correction in gas phase
    E_corr_eps = pot_correct / (left_dielectric_x + (domain_length-left_dielectric_x) * eps_DI)
    E_corr_gas = E_corr_eps * eps_DI
    print *, pot_correct, E_corr_eps, E_corr_gas

    field_fc(1:left_dielectric_iface-1) = field_fc(1:left_dielectric_iface-1) + E_corr_eps
    field_fc(left_dielectric_iface:domain_ncell+1) = &
         field_fc(left_dielectric_iface:domain_ncell+1) + E_corr_gas

    ! Determine cell-centered field
    field_cc(1:left_dielectric_iface-1) = E_corr_gas
    do iz = left_dielectric_iface, domain_ncell
       field_cc(iz) = 0.5_dp * (field_fc(iz) + field_fc(iz+1))
    end do
  end subroutine compute_field

  !> Get the electric field at a position in the domain (useful for the particle model)
  real(dp) function get_field_at(pos)
    real(dp), intent(in) :: pos
    real(dp) :: Efield_pos, temp
    integer :: lowIx

    error stop "TODO"
    ! EF_values(1) is defined at -0.5 * domain_dx
    lowIx = nint(pos * domain_inv_dx) + 1
    lowIx = min(domain_ncell, max(1, lowIx))

    Efield_pos = (lowIx - 1.5_dp) * domain_dx
    temp = (pos - Efield_pos) * domain_inv_dx

    ! Do linear interpolation between lowIx and lowIx + 1 in the Efield array, given the position
    EF_get_at_pos = (1.0_dp - temp) * EF_values(lowIx) + temp * EF_values(lowIx+1)

  end function get_field_at

  ! real(dp) function field_emission(fld)
  ! use m_units_constants
  !   real(dp), intent(in) :: fld
  !   real(dp)             :: W_ev, A, T

  !   W_ev = sqrt(UC_elem_charge * fld/(4*UC_pi*UC_eps0))
  !   A = 120 * (1.0_dp/UC_elem_charge) * 10000
  !   T = 270_dp

  !   field_emission = A * T**2 * exp(-UC_elem_charge*(work_fun-W_ev)/(UC_boltzmann_const*T))
  ! end function field_emission

  elemental function get_dens(x) result(dens)
    real(dp), intent(in) :: x
    real(dp)             :: dens

    if (x > left_dielectric_x) then
       select case (init_type)
       case (init_gaussian_type)
          dens = init_dens * exp(-(x - init_location)**2 / (2 * init_width**2))
       case (init_block_type)
          if ((x - init_location) < init_width) dens = init_dens
       case default
          error stop "get_dens: wrong argument"
       end select
    end if
  end subroutine get_dens

  elemental function init_elec_dens(x) result(elec_dens)
    real(dp), intent(in) :: x
    real(dp)             :: elec_dens
    type(LT_loc_t)       :: loc

    if (init_seed_sign < 1) then
       elec_dens = get_dens(x)
    else
       elec_dens = 0.0_dp
    end if
  end function init_elec_dens

  elemental function init_pos_ion_dens(x) result(pos_ion_dens)
    real(dp), intent(in) :: x
    real(dp)             :: pos_ion_dens
    type(LT_loc_t)       :: loc

    if (init_seed_sign > -1) then
       pos_ion_dens = get_dens(x)
    else
       pos_ion_dens = 0.0_dp
    end if
  end function init_pos_ion_dens

  elemental function init_energy_dens(x) result(energy_dens)
    real(dp), intent(in) :: x
    real(dp)             :: energy_dens
    type(LT_loc_t)       :: loc

    if (init_seed_sign < 1) then
       energy_dens = get_dens(x) * init_energy
    else
       energy_dens = 0.0_dp
    end if
  end function init_energy_dens

end module m_generic
