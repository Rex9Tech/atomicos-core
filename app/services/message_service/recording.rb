module MessageService
  class Recording < Base
    TITLE_REQUIRED = "recording.title_required"
    TITLE_PARAMETER_MISSING = "recording.title_parameter_missing"
    RECORDING_CREATED = "recording.created"
    RECORDING_UPDATED = "recording.updated"
    RECORDING_FINISHED = "recording.finished"
    RECORDING_FETCHED = "recording.fetched"
    RECORDING_NOT_FOUND = "recording.not_found"
    UPDATE_FAILED = "recording.update_failed"
  end
end
