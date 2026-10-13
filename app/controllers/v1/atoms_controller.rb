# app/controllers/v1/atoms_controller.rb
class V1::AtomsController < V1::ApplicationController
  before_action :set_atom, only: [ :show, :update, :destroy, :read_assets, :create_asset, :destroy_asset ]

  # GET /v1/atoms
  def index
    atoms = current_user.atoms.recent
    atoms = atoms.where(status: params[:status]) if params[:status].present?
    atoms = atoms.in_category(params[:category_id]) if params[:category_id].present?
    atoms = atoms.where("title ILIKE ?", "%#{params[:search]}%") if params[:search].present?
    pagy, records = pagy(:offset, atoms, limit: params[:limit])

    render_json_response(
      status_code: 200,
      message: atom_message(MessageService::Atom::ATOMS_FETCHED),
      **AtomSerializer.collection_pagy(records, pagy)
    )
  end

  # GET /v1/atoms/:id
  def show
    render_json_response(
      status_code: 200,
      message: atom_message(MessageService::Atom::ATOM_FETCHED),
      data: { atom: atom_payload(@atom) }
    )
  end

  # POST /v1/atoms
  def create
    atom = current_user.atoms.new(sanitized_atom_params)
    atom.source = AtomConstants::Source::NOTE if atom.source.blank?

    if atom.save
      broadcast_atom_event(
        NotificationConstants::NotificationType::ATOM_UPDATED,
        atom
      )

      render_json_response(
        status_code: 201,
        message: atom_message(MessageService::Atom::ATOM_CREATED),
        data: { atom: atom_payload(atom) }
      )
    else
      render_json_response(
        status_code: 422,
        message: atom_message(MessageService::Atom::CREATE_FAILED),
        error: atom.errors.full_messages.to_sentence
      )
    end
  end

  # PATCH/PUT /v1/atoms/:id
  def update
    if @atom.update(sanitized_atom_params)
      broadcast_atom_event(
        NotificationConstants::NotificationType::ATOM_UPDATED,
        @atom
      )

      render_json_response(
        status_code: 200,
        message: atom_message(MessageService::Atom::ATOM_UPDATED),
        data: { atom: atom_payload(@atom) }
      )
    else
      render_json_response(
        status_code: 422,
        message: atom_message(MessageService::Atom::UPDATE_FAILED),
        error: @atom.errors.full_messages.to_sentence
      )
    end
  end

  # DELETE /v1/atoms/:id (soft discard)
  def destroy
    @atom.discard!

    render_json_response(
      status_code: 200,
      message: atom_message(MessageService::Atom::ATOM_DELETED)
    )
  end

  # POST /v1/atoms/from-note
  def create_from_note
    note = params[:note]

    if note.blank?
      render_json_response(
        status_code: 422,
        message: atom_message(MessageService::Atom::NOTE_REQUIRED),
        error: atom_message(MessageService::Atom::NOTE_PARAMETER_MISSING)
      )
      return
    end

    atom = current_user.atoms.create!(
      title: params[:title].presence || note.to_s.truncate(50),
      source: AtomConstants::Source::NOTE,
      note: note,
      status: AtomConstants::Status::COMPLETED,
      category_id: resolved_category_id
    )

    broadcast_atom_event(
      NotificationConstants::NotificationType::ATOM_UPDATED,
      atom
    )

    render_json_response(
      status_code: 201,
      message: atom_message(MessageService::Atom::ATOM_CREATED),
      data: { atom: atom_payload(atom) }
    )
  end

  # POST /v1/atoms/from-url
  def create_from_url
    url = params[:url]

    if url.blank?
      render_json_response(
        status_code: 422,
        message: atom_message(MessageService::Atom::URL_REQUIRED),
        error: atom_message(MessageService::Atom::URL_PARAMETER_MISSING)
      )
      return
    end

    atom = current_user.atoms.create!(
      title: params[:title].presence || atom_message(MessageService::Atom::DEFAULT_URL_TITLE),
      source: AtomConstants::Source::URL,
      status: AtomConstants::Status::DRAFT,
      metadata: { url: url },
      category_id: resolved_category_id
    )

    process_url_content(atom, url)

    broadcast_atom_event(
      NotificationConstants::NotificationType::ATOM_UPDATED,
      atom
    )

    render_json_response(
      status_code: 201,
      message: atom_message(MessageService::Atom::ATOM_CREATED),
      data: { atom: atom_payload(atom) }
    )
  end

  # POST /v1/atoms/from-asset
  def create_from_asset
    asset = Asset.find_by(id: params[:asset_id])

    if asset.blank?
      render_json_response(
        status_code: 422,
        message: atom_message(MessageService::Atom::ASSET_REQUIRED),
        error: atom_message(MessageService::Atom::ASSET_NOT_FOUND)
      )
      return
    end

    atom = current_user.atoms.create!(
      title: params[:title].presence || asset.name.to_s.truncate(50),
      source: AtomConstants::Source::ASSET,
      status: AtomConstants::Status::DRAFT,
      duration_secs: asset.duration_secs,
      category_id: resolved_category_id,
      metadata: { "stt_language" => params[:language].presence }.compact
    )
    asset.update!(assetable: atom)

    # Audio processing runs in a job (with retries + a completion broadcast):
    # the provider can 503/429 transiently, and doing it inline made uploads
    # hang ~12s and skip silently when the call failed.
    if asset.format == AssetConstants::AssetFormat::AUDIO
      atom.update!(status: AtomConstants::Status::PROCESSING)
      Atoms::ProcessAssetContentJob.perform_later(atom.id)
    end

    broadcast_atom_event(
      NotificationConstants::NotificationType::ATOM_UPDATED,
      atom
    )

    render_json_response(
      status_code: 201,
      message: atom_message(MessageService::Atom::ATOM_CREATED),
      data: { atom: atom_payload(atom) }
    )
  end

  # POST /v1/atoms/from-share
  def create_from_share
    text = params[:text]
    url = params[:url]

    if text.blank? && url.blank?
      render_json_response(
        status_code: 422,
        message: atom_message(MessageService::Atom::SHARE_REQUIRED),
        error: atom_message(MessageService::Atom::SHARE_PARAMETER_MISSING)
      )
      return
    end

    atom = current_user.atoms.create!(
      title: params[:title].presence ||
             text.to_s.truncate(50).presence ||
             atom_message(MessageService::Atom::DEFAULT_SHARE_TITLE),
      source: AtomConstants::Source::SHARE,
      note: text.presence,
      status: AtomConstants::Status::DRAFT,
      metadata: { url: url }.compact,
      category_id: resolved_category_id
    )

    broadcast_atom_event(
      NotificationConstants::NotificationType::ATOM_UPDATED,
      atom
    )

    render_json_response(
      status_code: 201,
      message: atom_message(MessageService::Atom::ATOM_CREATED),
      data: { atom: atom_payload(atom) }
    )
  end

  # GET /v1/atoms/:id/assets
  def read_assets
    render_json_response(
      status_code: 200,
      message: atom_message(MessageService::Atom::ASSETS_FETCHED),
      data: { assets: @atom.assets.map { |a| AssetSerializer.new(a).serializable_hash[:data][:attributes] } }
    )
  end

  # POST /v1/atoms/:id/assets (attach an existing uploaded asset)
  def create_asset
    asset = Asset.find_by(id: params[:asset_id])

    if asset.blank?
      render_json_response(
        status_code: 422,
        message: atom_message(MessageService::Atom::ASSET_REQUIRED),
        error: atom_message(MessageService::Atom::ASSET_NOT_FOUND)
      )
      return
    end

    asset.update!(assetable: @atom)

    # The atom mirrors its source recording's real length. This also heals
    # durations reported by older clients, which sent the wall-clock timer
    # (longer than the captured audio whenever background chunks were lost).
    if asset.format == AssetConstants::AssetFormat::AUDIO &&
       asset.type != AssetConstants::AssetType::ATTACHMENT &&
       asset.duration_secs.present? &&
       @atom.duration_secs != asset.duration_secs
      @atom.update!(duration_secs: asset.duration_secs)
    end

    broadcast_atom_event(
      NotificationConstants::NotificationType::ASSET_PROCESSED,
      @atom
    )

    render_json_response(
      status_code: 201,
      message: atom_message(MessageService::Atom::ASSET_ATTACHED),
      data: { asset: AssetSerializer.new(asset).serializable_hash[:data][:attributes] }
    )
  end

  # DELETE /v1/atoms/:id/assets/:asset_id
  def destroy_asset
    asset = @atom.assets.find(params[:asset_id])
    asset.destroy!

    render_json_response(
      status_code: 200,
      message: atom_message(MessageService::Atom::ASSET_DETACHED)
    )
  rescue ActiveRecord::RecordNotFound
    render_json_response(
      status_code: 404,
      message: atom_message(MessageService::Atom::ASSET_NOT_FOUND)
    )
  end

  private

  def set_atom
    @atom = current_user.atoms.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_json_response(
      status_code: 404,
      message: atom_message(MessageService::Atom::ATOM_NOT_FOUND)
    )
  end

  def atom_payload(atom)
    AtomSerializer.new(atom).serializable_hash[:data][:attributes].merge(
      assets: atom.assets.map { |a| AssetSerializer.new(a).serializable_hash[:data][:attributes] }
    )
  end

  def broadcast_atom_event(type, atom)
    SocketService::Client.broadcast(
      user_id: current_user.id,
      message: atom_message(MessageService::Atom::ATOM_UPDATED),
      data: { type: type, atom_id: atom.id }
    )
  end

  # Best-effort synchronous fetch + AI summarize for URL imports. Rescued so a
  # slow/unreachable URL never blocks the atom from being created (stays draft).
  def process_url_content(atom, url)
    content = ContentFetchService.fetch(url)
    return if content.error.present?

    source_text = [ content.title, content.description, content.text ].compact_blank.join("\n\n")
    return if source_text.blank?

    summary = summarize_text(source_text)
    return if summary.blank?

    note_content = [ content.title, content.description ].compact_blank.join("\n\n")

    atom.update!(
      title: content.title.presence || atom.title,
      status: AtomConstants::Status::COMPLETED,
      note: note_content.presence,
      summary_blocks: [ { "type" => "summary", "text" => summary } ],
      metadata: atom.metadata.merge("content" => source_text.truncate(20_000))
    )
  rescue StandardError => e
    Rails.logger.error("[ATOM-URL] Failed to process URL for atom #{atom.id}: #{e.message}")
  end

  def summarize_text(text)
    messages = [
      { role: AiConstants::ChatRole::SYSTEM, content: AiConstants::AiPrompt::SUMMARIZE_MARKDOWN },
      { role: AiConstants::ChatRole::USER, content: text.truncate(12_000) }
    ]

    result = AiService::Client.chat(
      messages: messages,
      temperature: 0.5,
      max_tokens: 3_000
    )

    return "" if result[:error].present?

    AiService::Client.text_from(result)
  rescue StandardError
    ""
  end

  def atom_params
    params.require(:atom).permit(
      :title, :source, :status, :duration_secs, :participants_count, :note, :recording_status, :category_id, :meeting_at,
      summary_blocks: [], transcript_segments: [], metadata: {}
    )
  end

  # Category changes must point at one of the CURRENT USER's own categories —
  # a foreign or unknown id clears the field instead of leaking a reference
  # into another user's list. Accepts an explicit null to clear.
  #
  # meeting_at accepts an ISO-8601 string (parsed to the app timezone) or an
  # explicit null to clear; an unparsable value clears rather than 500-ing.
  def sanitized_atom_params
    attrs = atom_params
    if attrs.key?(:category_id)
      attrs[:category_id] = current_user.categories.find_by(id: attrs[:category_id])&.id
    end
    if attrs.key?(:meeting_at)
      raw = attrs[:meeting_at].to_s
      attrs[:meeting_at] =
        if raw.blank?
          nil
        else
          begin
            Time.zone.parse(raw)
          rescue ArgumentError
            nil
          end
        end
    end
    attrs
  end

  # Resolves the optional category_id param to one of the CURRENT USER's kept
  # categories (invalid or foreign ids simply leave the atom uncategorized
  # instead of 500-ing).
  def resolved_category_id
    raw = params[:category_id].presence
    return nil if raw.blank?

    current_user.categories.find_by(id: raw)&.id
  end

  def atom_message(key, **options)
    MessageService::Atom.t(key, **options)
  end
end
