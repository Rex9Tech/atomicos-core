class AddCategoryDomainPermissions < ActiveRecord::Migration[8.1]
  def up
    # Create the new permissions (categories) so IAM authorization stops
    # 403-ing regular users on the read endpoint and admins on management.
    Iam::Permission::RESOURCES.each do |resource|
      Iam::Permission::ACTIONS.each do |action|
        Iam::Permission.find_or_create_by!(action: action, resource: resource)
      end
    end

    super_admin = Iam::Role.find_by(name: IamConstants::Role::SUPER_ADMIN)
    admin = Iam::Role.find_by(name: IamConstants::Role::ADMIN)
    default_user = Iam::Role.find_by(name: IamConstants::Role::USER)

    # Super admin: every permission (covers the new ones).
    if super_admin
      Iam::Permission.find_each do |perm|
        Iam::RolePermission.find_or_create_by!(role: super_admin, permission: perm)
      end
    end

    # Admin: everything except restricted resources.
    if admin
      Iam::Permission.where.not(resource: IamConstants::Role::RESTRICTED_FOR_ADMIN).find_each do |perm|
        Iam::RolePermission.find_or_create_by!(role: admin, permission: perm)
      end
    end

    # Default user role: mirror the seed's DefaultPermissions::USER.
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
    Iam::Permission.where(resource: "categories").destroy_all
  end
end
