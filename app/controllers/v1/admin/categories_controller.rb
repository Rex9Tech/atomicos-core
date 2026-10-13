# app/controllers/v1/admin/categories_controller.rb

class V1::Admin::CategoriesController < V1::ApplicationController
  before_action :set_category, only: %i[update destroy discard]
  before_action :set_category_including_discarded, only: :undiscard

  # GET /v1/admin/categories
  def index
    categories = Category.ordered
    pagy, records = pagy(:offset, categories, limit: params[:limit])

    render_json_response(
      status_code: 200,
      message: category_message(MessageService::Category::CATEGORIES_FETCHED),
      **CategorySerializer.collection_pagy(records, pagy)
    )
  end

  # POST /v1/admin/categories
  def create
    category = Category.new(category_params)

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

  # PATCH/PUT /v1/admin/categories/:id
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

  # DELETE /v1/admin/categories/:id (soft discard — atoms keep their history)
  def destroy
    @category.discard!

    render_json_response(
      status_code: 200,
      message: category_message(MessageService::Category::CATEGORY_DELETED)
    )
  end

  # POST /v1/admin/categories/:id/discard
  def discard
    @category.discard!

    render_json_response(
      status_code: 200,
      message: category_message(MessageService::Category::CATEGORY_DELETED)
    )
  end

  # POST /v1/admin/categories/:id/undiscard
  def undiscard
    @category.undiscard!

    render_json_response(
      status_code: 200,
      message: category_message(MessageService::Category::CATEGORY_UPDATED),
      data: { category: category_payload(@category) }
    )
  end

  private

  def set_category
    @category = Category.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_json_response(
      status_code: 404,
      message: category_message(MessageService::Category::CATEGORY_NOT_FOUND)
    )
  end

  def set_category_including_discarded
    @category = Category.with_discarded.find(params[:id])
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
