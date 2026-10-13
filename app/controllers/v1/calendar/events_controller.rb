# app/controllers/v1/calendar/events_controller.rb
class V1::Calendar::EventsController < V1::ApplicationController
  before_action :set_event, only: [ :show, :update, :destroy ]

  # GET /v1/calendar/events
  def index
    events = current_user.calendar_events.by_start
    events = events.upcoming if params[:upcoming].present?
    pagy, records = pagy(:offset, events, limit: params[:limit])

    render_json_response(
      status_code: 200,
      message: calendar_message(MessageService::Calendar::EVENTS_FETCHED),
      data: CalendarEventSerializer.paginated(records, pagy),
      pagy: pagy
    )
  end

  # GET /v1/calendar/events/:id
  def show
    render_json_response(
      status_code: 200,
      message: calendar_message(MessageService::Calendar::EVENT_FETCHED),
      data: { calendar_event: event_payload(@event) }
    )
  end

  # POST /v1/calendar/events
  def create
    event = current_user.calendar_events.new(event_params)

    if event.save
      render_json_response(
        status_code: 201,
        message: calendar_message(MessageService::Calendar::EVENT_CREATED),
        data: { calendar_event: event_payload(event) }
      )
    else
      render_json_response(
        status_code: 422,
        message: calendar_message(MessageService::Calendar::CREATE_FAILED),
        error: event.errors.full_messages.to_sentence
      )
    end
  end

  # PATCH/PUT /v1/calendar/events/:id
  def update
    if @event.update(event_params)
      render_json_response(
        status_code: 200,
        message: calendar_message(MessageService::Calendar::EVENT_UPDATED),
        data: { calendar_event: event_payload(@event) }
      )
    else
      render_json_response(
        status_code: 422,
        message: calendar_message(MessageService::Calendar::UPDATE_FAILED),
        error: @event.errors.full_messages.to_sentence
      )
    end
  end

  # DELETE /v1/calendar/events/:id (soft discard)
  def destroy
    @event.discard!

    render_json_response(
      status_code: 200,
      message: calendar_message(MessageService::Calendar::EVENT_DELETED)
    )
  end

  private

  def set_event
    @event = current_user.calendar_events.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_json_response(
      status_code: 404,
      message: calendar_message(MessageService::Calendar::EVENT_NOT_FOUND)
    )
  end

  def event_payload(event)
    CalendarEventSerializer.new(event).serializable_hash[:data][:attributes]
  end

  def event_params
    params.require(:calendar_event).permit(
      :title, :start_at, :end_at, :description, :status, metadata: {}
    )
  end

  def calendar_message(key, **options)
    MessageService::Calendar.t(key, **options)
  end
end
