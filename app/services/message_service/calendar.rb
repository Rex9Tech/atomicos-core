module MessageService
  class Calendar < Base
    TITLE_REQUIRED = "calendar.title_required"
    TITLE_PARAMETER_MISSING = "calendar.title_parameter_missing"
    EVENTS_FETCHED = "calendar.events_fetched"
    EVENT_FETCHED = "calendar.event_fetched"
    EVENT_CREATED = "calendar.event_created"
    EVENT_UPDATED = "calendar.event_updated"
    EVENT_DELETED = "calendar.event_deleted"
    EVENT_NOT_FOUND = "calendar.event_not_found"
    CREATE_FAILED = "calendar.create_failed"
    UPDATE_FAILED = "calendar.update_failed"
  end
end
