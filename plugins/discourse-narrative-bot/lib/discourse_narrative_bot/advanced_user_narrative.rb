module DiscourseNarrativeBot
  class AdvancedUserNarrative < Base
    I18N_KEY = "discourse_narrative_bot.advanced_user_narrative".freeze
    BADGE_NAME = 'Licensed'.freeze

    TRANSITION_TABLE = {
      begin: {
        next_state: :tutorial_edit,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.edit.instructions") },
        init: {
          action: :start_advanced_track
        }
      },

      tutorial_edit: {
        next_state: :tutorial_delete,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.delete.instructions") },
        edit: {
          action: :reply_to_edit
        },
        reply: {
          next_state: :tutorial_edit,
          action: :missing_edit
        }
      },

      tutorial_delete: {
        next_state: :tutorial_recover,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.recover.instructions") },
        delete: {
          action: :reply_to_delete
        },
        reply: {
          next_state: :tutorial_delete,
          action: :missing_delete
        }
      },

      tutorial_recover: {
        next_state: :tutorial_category_hashtag,
        next_instructions: Proc.new do
          category = Category.secured.last
          slug = category.slug

          if parent_category = category.parent_category
            slug = "#{parent_category.slug}#{CategoryHashtag::SEPARATOR}#{slug}"
          end

          I18n.t("#{I18N_KEY}.category_hashtag.instructions",
            category: "##{slug}"
          )
        end,
        recover: {
          action: :reply_to_recover
        },
        reply: {
          next_state: :tutorial_recover,
          action: :missing_recover
        }
      },

      tutorial_category_hashtag: {
        next_state: :tutorial_change_topic_notification_level,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.change_topic_notification_level.instructions") },
        reply: {
          action: :reply_to_category_hashtag
        }
      },

      tutorial_change_topic_notification_level: {
        next_state: :tutorial_poll,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.poll.instructions") },
        topic_notification_level_changed: {
          action: :reply_to_topic_notification_level_changed
        },
        reply: {
          next_state: :tutorial_notification_level,
          action: :missing_topic_notification_level_change
        }
      },

      tutorial_poll: {
        next_state: :tutorial_details,
        next_instructions: Proc.new { I18n.t("#{I18N_KEY}.details.instructions") },
        reply: {
          action: :reply_to_poll
        }
      },

      tutorial_details: {
        next_state: :end,
        reply: {
          action: :reply_to_details
        }
      }
    }

    def self.can_start?(user)
      return true if user.staff? || !SiteSetting.enable_badges
      user.badges.where(name: DiscourseNarrativeBot::NewUserNarrative::BADGE_NAME).exists?
    end

    def self.reset_trigger
      I18n.t('discourse_narrative_bot.advanced_user_narrative.reset_trigger')
    end

    def reset_bot(user, post)
      if pm_to_bot?(post)
        reset_data(user, { topic_id: post.topic_id })
      else
        reset_data(user)
      end

      Jobs.enqueue_in(2.seconds, :narrative_init, user_id: user.id, klass: self.class.to_s)
    end

    private

    def init_tutorial_edit
      data = get_data(@user)

      fake_delay

      post = PostCreator.create!(@user, {
        raw: I18n.t(
          "#{I18N_KEY}.edit.bot_created_post_raw",
          discobot_username: self.class.discobot_user.username
        ),
        topic_id: data[:topic_id],
        skip_bot: true
      })

      set_state_data(:post_id, post.id)
      post
    end

    def init_tutorial_recover
      data = get_data(@user)

      post = PostCreator.create!(@user, {
        raw: I18n.t(
          "#{I18N_KEY}.recover.deleted_post_raw",
          discobot_username: self.class.discobot_user.username
        ),
        topic_id: data[:topic_id],
        skip_bot: true
      })

      set_state_data(:post_id, post.id)
      PostDestroyer.new(@user, post, skip_bot: true).destroy
    end

    def start_advanced_track
      raw = I18n.t("#{I18N_KEY}.start_message", username: @user.username)

      raw = <<~RAW
      #{raw}

      #{instance_eval(&@next_instructions)}
      RAW

      opts = {
        title: I18n.t("#{I18N_KEY}.title"),
        target_usernames: @user.username,
        archetype: Archetype.private_message
      }

      if @post &&
         @post.archetype == Archetype.private_message &&
         @post.topic.topic_allowed_users.pluck(:user_id).include?(@user.id)

        opts = opts.merge(topic_id: @post.topic_id)
      end

      if @data[:topic_id]
        opts = opts.merge(topic_id: @data[:topic_id])
      end
      post = reply_to(@post, raw, opts)

      @data[:topic_id] = post.topic_id
      @data[:track] = self.class.to_s
      post
    end

    def reply_to_edit
      return unless valid_topic?(@post.topic_id)

      fake_delay

      raw = <<~RAW
      #{I18n.t("#{I18N_KEY}.edit.reply")}

      #{instance_eval(&@next_instructions)}
      RAW

      reply_to(@post, raw)
    end

    def missing_edit
      post_id = get_state_data(:post_id)
      return unless valid_topic?(@post.topic_id) && post_id != @post.id

      fake_delay

      unless @data[:attempted]
        reply_to(@post, I18n.t("#{I18N_KEY}.edit.not_found",
          url: Post.find_by(id: post_id).url
        ))
      end

      enqueue_timeout_job(@user)
      false
    end

    def reply_to_delete
      return unless valid_topic?(@topic_id)

      fake_delay

      raw = <<~RAW
      #{I18n.t("#{I18N_KEY}.delete.reply")}

      #{instance_eval(&@next_instructions)}
      RAW

      PostCreator.create!(self.class.discobot_user,
        raw: raw,
        topic_id: @topic_id
      )
    end

    def missing_delete
      return unless valid_topic?(@post.topic_id)
      fake_delay
      reply_to(@post, I18n.t("#{I18N_KEY}.delete.not_found")) unless @data[:attempted]
      enqueue_timeout_job(@user)
      false
    end

    def reply_to_recover
      return unless valid_topic?(@post.topic_id)

      fake_delay

      raw = <<~RAW
      #{I18n.t("#{I18N_KEY}.recover.reply")}

      #{instance_eval(&@next_instructions)}
      RAW

      PostCreator.create!(self.class.discobot_user,
        raw: raw,
        topic_id: @post.topic_id
      )
    end

    def missing_recover
      return unless valid_topic?(@post.topic_id) &&
        post_id = get_state_data(:post_id) && @post.id != post_id

      fake_delay
      reply_to(@post, I18n.t("#{I18N_KEY}.recover.not_found")) unless @data[:attempted]
      enqueue_timeout_job(@user)
      false
    end

    def reply_to_category_hashtag
      topic_id = @post.topic_id
      return unless valid_topic?(topic_id)

      if Nokogiri::HTML.fragment(@post.cooked).css('.hashtag').size > 0
        raw = <<~RAW
          #{I18n.t("#{I18N_KEY}.category_hashtag.reply")}

          #{instance_eval(&@next_instructions)}
        RAW

        fake_delay
        reply_to(@post, raw)
      else
        fake_delay
        reply_to(@post, I18n.t("#{I18N_KEY}.category_hashtag.not_found")) unless @data[:attempted]
        enqueue_timeout_job(@user)
        false
      end
    end

    def missing_topic_notification_level_change
      return unless valid_topic?(@post.topic_id)

      fake_delay
      reply_to(@post, I18n.t("#{I18N_KEY}.change_topic_notification_level.not_found")) unless @data[:attempted]
      enqueue_timeout_job(@user)
      false
    end

    def reply_to_topic_notification_level_changed
      return unless valid_topic?(@topic_id)

      fake_delay
      raw = <<~RAW
        #{I18n.t("#{I18N_KEY}.change_topic_notification_level.reply")}

        #{instance_eval(&@next_instructions)}
      RAW

      fake_delay

      post = PostCreator.create!(self.class.discobot_user,
        raw: raw,
        topic_id: @topic_id
      )
      enqueue_timeout_job(@user)
      post
    end

    def reply_to_poll
      topic_id = @post.topic_id
      return unless valid_topic?(topic_id)

      if Nokogiri::HTML.fragment(@post.cooked).css(".poll").size > 0
        raw = <<~RAW
          #{I18n.t("#{I18N_KEY}.poll.reply")}

          #{instance_eval(&@next_instructions)}
        RAW

        fake_delay
        reply_to(@post, raw)
      else
        fake_delay
        reply_to(@post, I18n.t("#{I18N_KEY}.poll.not_found")) unless @data[:attempted]
        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_details
      topic_id = @post.topic_id
      return unless valid_topic?(topic_id)

      fake_delay

      if Nokogiri::HTML.fragment(@post.cooked).css("details").size > 0
        reply_to(@post, I18n.t("#{I18N_KEY}.details.reply"))
      else
        reply_to(@post, I18n.t("#{I18N_KEY}.details.not_found")) unless @data[:attempted]
        enqueue_timeout_job(@user)
        false
      end
    end

    def reply_to_wiki
      topic_id = @post.topic_id
      return unless valid_topic?(topic_id)

      fake_delay

      if @post.wiki
        reply_to(@post, I18n.t("#{I18N_KEY}.wiki.reply"))
      else
        reply_to(@post, I18n.t("#{I18N_KEY}.wiki.not_found")) unless @data[:attempted]
        enqueue_timeout_job(@user)
        false
      end
    end

    def end_reply
      fake_delay

      reply_to(@post, I18n.t("#{I18N_KEY}.end.message",
        certificate: certificate('advanced')
      ))
    end

    def synchronize(user)
      if Rails.env.test?
        yield
      else
        DistributedMutex.synchronize("advanced_user_narrative_#{user.id}") { yield }
      end
    end
  end
end
