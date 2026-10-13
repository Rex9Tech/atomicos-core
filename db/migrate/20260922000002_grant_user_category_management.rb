class GrantUserCategoryManagement < ActiveRecord::Migration[8.1]
  def up
    # Categories are now managed by every user (not admins only) — refresh the
    # role grants so the default user role gets full CRUD on its own rows.
    Iam::Permission::RESOURCES.each do |resource|
      Iam::Permission::ACTIONS.each do |action|
        Iam::Permission.find_or_create_by!(action: action, resource: resource)
      end
    end

    super_admin = Iam::Role.find_by(name: IamConstants::Role::SUPER_ADMIN)
    admin = Iam::Role.find_by(name: IamConstants::Role::ADMIN)
    default_user = Iam::Role.find_by(name: IamConstants::Role::USER)

    if super_admin
      Iam::Permission.find_each do |perm|
        Iam::RolePermission.find_or_create_by!(role: super_admin, permission: perm)
      end
    end

    if admin
      Iam::Permission.where.not(resource: IamConstants::Role::RESTRICTED_FOR_ADMIN).find_each do |perm|
        Iam::RolePermission.find_or_create_by!(role: admin, permission: perm)
      end
    end

    # Mirrors the seed's DefaultPermissions::USER (categories = all actions now).
    if default_user
      IamConstants::DefaultPermissions::USER.each do |entry|
        entry[:actions].each do |action|
          perm = Iam::Permission.find_by(resource: entry[:resource], action: action)
          Iam::RolePermission.find_or_create_by!(role: default_user, permission: perm) if perm
        end
      end
    end
  end

  def down
    # Revert to read-only for the default user role.
    default_user = Iam::Role.find_by(name: IamConstants::Role::USER)
    return unless default_user

    %w[create update delete].each do |action|
      perm = Iam::Permission.find_by(resource: "categories", action: action)
      Iam::RolePermission.where(role: default_user, permission: perm).destroy_all if perm
    end
  end
end
