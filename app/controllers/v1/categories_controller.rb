# app/controllers/v1/categories_controller.rb

# Personal atom-category taxonomy — every user manages their OWN list.
# (The /v1/admin/categories endpoints remain for admin-panel oversight.)
class V1::CategoriesController < V1::ApplicationController
  before_action :set_category, only: %i[update destroy]

  # GET /v1/categories
  def index
    categories = current_user.categories.ordered

    render_json_response(
      status_code: 200,
      message: category_message(MessageService::Category::CATEGORIES_FETCHED),
      data: CategorySerializer.new(categories).serializable_hash[:data]
    )
  end

  # POST /v1/categories
  def create
    category = current_user.categories.new(category_params)

    if category.save
      render_json_response(
        status_code: 201,
        message: category_message(MessageService::Category::CATEGORY_CREATED),
        data: { category: category_payload(category) }
      )
    else
      render_json_response(
        status_code: 422,
        message: category_message(MessageService::Category::CREATE_FAILED),
        error: category.errors.full_messages.to_sentence
      )
    end
  end

  # PATCH/PUT /v1/categories/:id
  def update
    if @category.update(category_params)
      render_json_response(
        status_code: 200,
        message: category_message(MessageService::Category::CATEGORY_UPDATED),
        data: { category: category_payload(@category) }
      )
    else
      render_json_response(
        status_code: 422,
        message: category_message(MessageService::Category::UPDATE_FAILED),
        error: @category.errors.full_messages.to_sentence
      )
    end
  end

  # DELETE /v1/categories/:id (soft discard — atoms keep their content)
  def destroy
    @category.discard!

    render_json_response(
      status_code: 200,
      message: category_message(MessageService::Category::CATEGORY_DELETED)
    )
  end

  private

  def set_category
    @category = current_user.categories.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_json_response(
      status_code: 404,
      message: category_message(MessageService::Category::CATEGORY_NOT_FOUND)
    )
  end

  def category_params
    params.require(:category).permit(:name, :slug, :description, :position)
  end

  def category_payload(category)
    CategorySerializer.new(category).serializable_hash[:data][:attributes]
  end

  def category_message(key, **options)
    MessageService::Category.t(key, **options)
  end
end
