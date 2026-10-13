# app/services/message_service/category.rb

module MessageService
  class Category < Base
    CATEGORIES_FETCHED = "category.categories_fetched"
    CATEGORY_FETCHED = "category.category_fetched"
    CATEGORY_CREATED = "category.category_created"
    CATEGORY_UPDATED = "category.category_updated"
    CATEGORY_DELETED = "category.category_deleted"
    CATEGORY_NOT_FOUND = "category.category_not_found"
    NAME_REQUIRED = "category.name_required"
    NAME_PARAMETER_MISSING = "category.name_parameter_missing"
    CREATE_FAILED = "category.create_failed"
    UPDATE_FAILED = "category.update_failed"
  end
end
