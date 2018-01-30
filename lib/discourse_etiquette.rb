module DiscourseEtiquette
  ANALYZE_COMMENT_ENDPOINT = 'https://commentanalyzer.googleapis.com/v1alpha1/comments:analyze'
  class NetworkError < StandardError; end

  class AnalyzeComment
    def initialize(post, user_id)
      @post = post
      @user_id = user_id
    end

    def to_json
      {
        comment: {
          text: @post.raw
        },
        requestedAttributes: {
          TOXICITY: {
            scoreType: 'PROBABILITY'
          },
          SEVERE_TOXICITY: {
            scoreType: 'PROBABILITY'
          }
        },
        doNotStore: true,
        sessionId: "#{Discourse.base_url}_#{@user_id}"
      }.to_json
    end
  end

  def self.proxy_request_options
    @proxy_request_options ||= {
      connect_timeout: 5, # in seconds
      read_timeout: 5,
      write_timeout: 10,
      ssl_verify_peer: true,
      retry_limit: 0
    }
  end

  def self.extract_value_from_analyze_comment_response(response)
    begin
      Hash[response['attributeScores'].map do |attribute|
        [attribute[0].downcase, attribute[1].dig('summaryScore', 'value') || 0.0]
      end].symbolize_keys
    rescue
      Hash.new.tap do |dummy|
        dummy.default = 0.0
      end
    end
  end

  def self.flag_on_scores(scores)
    if scores[:toxicity] > SiteSetting.etiquette_post_min_toxicity_confidence ||
      scores[:severe_toxicity] > SiteSetting.etiquette_post_min_severe_toxicity_confidence
      PostAction.act(
        Discourse.system_user,
        post,
        PostActionType.types[:notify_moderators],
        message: I18n.t('etiquette_flag_message')
      )
    end
  end

  def self.check_post_toxicity(post)
    response = self.request_analyze_comment(post)
    scores = self.extract_value_from_analyze_comment_response(JSON.load(response.body))
    self.flag_on_scores(scores)
    scores
  end

  RawContent = Struct.new(:raw, :user_id)
  def self.check_content_toxicity(content, user_id)
    post = RawContent.new(content, user_id)
    response = self.request_analyze_comment(post)
    self.extract_value_from_analyze_comment_response(JSON.load(response.body))
  end

  def self.request_analyze_comment(post)
    analyze_comment = AnalyzeComment.new(post, post.user_id)

    @conn ||= Excon.new(
      "#{ANALYZE_COMMENT_ENDPOINT}?key=#{SiteSetting.etiquette_google_api_key}",
      self.proxy_request_options
    )

    body = analyze_comment.to_json
    headers = {
      'Accept' => '*/*',
      'Content-Length' => body.bytesize,
      'Content-Type' => 'application/json',
      'User-Agent' => "Discourse/#{Discourse::VERSION::STRING}",
    }
    begin
      @conn.post(headers: headers, body: body, persistent: true)
    rescue
      raise NetworkError, "Excon had some problems with Google's Perspective API."
    end
  end

  def self.should_check_post?(post)
    return false if post.blank? || (!SiteSetting.etiquette_enabled?)

    # admin can choose whether to flag private messages. The message will be sent to moderators.
    return false if !SiteSetting.etiquette_check_private_message && post.topic.private_message?

    stripped = post.raw.strip

    # If the entire post is a URI we skip it. This might seem counter intuitive but
    # Discourse already has settings for max links and images for new users. If they
    # pass it means the administrator specifically allowed them.
    uri = URI(stripped) rescue nil
    return false if uri

    # Otherwise check the post!
    true
  end
end
