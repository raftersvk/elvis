# frozen_string_literal: true

class ActivitiesApplicationsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:create]
  skip_before_action :authenticate_user!, only: [:new]

  def index
    authorize_teachers = Parameter.get_value("activity_applications.authorize_teachers", default: false)

    if authorize_teachers
      raise CanCan::AccessDenied unless  current_user&.is_admin || current_user&.is_teacher
    end

    season = Season.current_apps_season
    @admins = User.admins.as_json only: %i[id first_name last_name full_name]

    if current_user.is_admin
      @seasons = Season.all_seasons_cached

      @adherent_count = Payment
                          .joins(due_payment: :payment_schedule)
                          .where({
                                   payment_status_id: nil,
                                   due_payments: {
                                     number: 0,
                                     payment_schedules: {
                                       season_id: season&.id || 0,
                                     },
                                   },
                                 })
                          .map(&:adjusted_amount)
                          .compact
                          .sum.to_i / 15

      # User.joins(:activity_applications).where(activity_applications: { season_id: season.id }).uniq.count
      @applications_count = ActivityApplication.where(season: season).count
      @applications_to_process = ActivityApplication.where(season: season)
                                                    .joins(:activity_application_status)
                                                    .merge(
                                                      ActivityApplicationStatus.where(id: ActivityApplicationStatus::TREATMENT_PENDING_ID)
                                                    ).count
      @processing_applications_count = ActivityApplication.where(season: season)
                                                          .joins(:activity_application_status)
                                                          .merge(
                                                            # ActivityApplicationStatus.where("label != ? AND label != ? AND label != ?", "Cours attribué", "Arrêté",
                                                            #                                 "En attente de traitement")
                                                            ActivityApplicationStatus.where.not(id: [ActivityApplicationStatus::TREATMENT_PENDING_ID, ActivityApplicationStatus::STOPPED_ID, ActivityApplicationStatus::ACTIVITY_ATTRIBUTED_ID])
                                                          ).count

      @processed_applications_count = ActivityApplication.where(season: season)
                                                         .joins(:activity_application_status)
                                                         .merge(ActivityApplicationStatus.where(id: [ActivityApplicationStatus::ACTIVITY_ATTRIBUTED_ID, ActivityApplicationStatus::STOPPED_ID]))
                                                         .count
    end

    # activity_refs = ActivityRef.all.reject { |ar| ar.activity_type == "child" || ar.activity_type == "cham" }.uniq(&:kind)
    # activity_refs << ActivityRef.all.select { |ar| ar.activity_type == "child" }
    # activity_refs << ActivityRef.all.select { |ar| ar.activity_type == "cham" }
    @activities = ActivityRef.all.as_json

    @statuses = ActivityApplicationStatus.all

    @evaluation_level_refs = EvaluationLevelRef.all
  end

  def list
    query = get_query_from_params

    respond_to do |format|
      format.json { render json: applications_list_json(query), content_type: "application/json" }
      format.csv { render plain: applications_list_csv(query), content_type: "text/csv" }
    end
  end

  def show

    # @type [ActivityApplication]
    activity_application = ActivityApplication.includes({
                                                          user: {
                                                            levels: {
                                                              evaluation_level_ref: {},
                                                              activity_ref: [:activity_ref_kind],
                                                              season: {},
                                                            },
                                                            telephones: {},
                                                            planning: [:time_intervals],
                                                            instruments: {},
                                                            adhesions: {},
                                                            activity_applications: {
                                                              pre_application_activity: {},
                                                              pre_application_desired_activity: {},
                                                              activity_application_status: {},
                                                              desired_activities: {
                                                                activity_ref: [:activity_ref_kind],
                                                                activity: {
                                                                  time_interval: {},
                                                                  activity_ref: {},
                                                                },
                                                              },
                                                              season: {},
                                                            },
                                                          },
                                                          activity_refs: [:activity_ref_kind],
                                                          activity_application_status: {},
                                                          pre_application_activity: {
                                                            activity: {
                                                              activity_ref: [:activity_ref_kind],
                                                              time_interval: {},
                                                              room: {},
                                                            },
                                                          },
                                                          pre_application_desired_activity: {},
                                                          desired_activities: {
                                                            options: {},
                                                            user: {},
                                                            activity_ref: [:activity_ref_kind],
                                                          },
                                                          evaluation_appointments: %i[time_interval teacher],
                                                          comments: [:user],
                                                          season: {},
                                                        }).find(params[:id])

    authorize! :read, activity_application

    # None of applications desired activities are complete
    if activity_application.season.start.past? && activity_application.desired_activities.find do |da|
      da.is_validated || da.options.count.positive?
    end.nil?
      # resulting date should be <= stopped at date AND <= season end
      new_start_date = [activity_application.season.end, activity_application.stopped_at, Time.zone.now].compact.min
      activity_application.update!(begin_at: new_start_date)
    end

    tmp_activities_applications = activity_application
                                    .user
                                    .activity_applications
                                    .where(season_id: Season.current_apps_season&.id)
                                    .to_a

    unless current_user.is_admin
      tmp_activities_applications = tmp_activities_applications.filter{|a|
               Abilities::ActivityApplicationAbilities.is_activity_application_concern_any_activity_ref?(a, current_user.activity_refs.pluck(:id))
             }
    end

    @activity_application = activity_application.as_json({
                                                           include: {
                                                             user: {
                                                               include: {
                                                                 levels: { include: {
                                                                   evaluation_level_ref: {},
                                                                   activity_ref: { include: [:activity_ref_kind] },
                                                                   season: {},
                                                                 } },
                                                                 telephones: {},
                                                                 planning: {
                                                                   include: [:time_intervals],
                                                                 },
                                                                 instruments: {},
                                                                 adhesions: {},
                                                               },
                                                             },
                                                             activity_refs: { include: [:activity_ref_kind] },
                                                             activity_application_status: {},
                                                             pre_application_activity: {
                                                               include: {
                                                                 activity: {
                                                                   include: {
                                                                     teacher: {},
                                                                     activity_ref: { include: [:activity_ref_kind] },
                                                                     time_interval: {},
                                                                     room: {},
                                                                   },
                                                                 },
                                                               },
                                                             },
                                                             pre_application_desired_activity: {},
                                                             desired_activities: {
                                                               include: {
                                                                 options: {},
                                                                 user: {},
                                                                 activity_ref: { include: [:activity_ref_kind] },
                                                               },
                                                             },
                                                             evaluation_appointments: {
                                                               include: %i[time_interval teacher],
                                                             },
                                                             comments: { include: [:user] },
                                                             season: {},
                                                           },
                                                         })

    @activity_application["user"]["family_links_with_user"] = activity_application
                                                                .user
                                                                .family_links_with_user(activity_application.season)

    @activity_application["user"]["activity_applications"] = tmp_activities_applications.as_json({
                                                                                                   include: {
                                                                                                     pre_application_activity: {},
                                                                                                     pre_application_desired_activity: {},
                                                                                                     activity_application_status: {},
                                                                                                     desired_activities: {
                                                                                                       include: {
                                                                                                         activity_ref: { include: [:activity_ref_kind] },
                                                                                                         activity: {
                                                                                                           include: {
                                                                                                             time_interval: {},
                                                                                                             teacher: {},
                                                                                                             activity_ref: {},
                                                                                                           },
                                                                                                         },
                                                                                                       },
                                                                                                     },
                                                                                                     season: {},
                                                                                                   },
                                                                                                 }
                                                                                               )

    respond_to do |format|
      format.html do
        payer = activity_application.user.get_first_paying_family_member
        @payer = payer.as_json(except: %i[created_at updated_at authentication_token])
        @payer[:kind] = payer.class.to_s unless @payer.nil?

        @activity_refs = ActivityRef.all.as_json(methods: [:display_name])
        @statuses = ActivityApplicationStatus.all
        @levels = EvaluationLevelRef.all
        @seasons = Season.all_seasons_cached
        @student_evaluation_questions = Question.student_evaluation_questions.all
        @application_change_questions = Question.application_change_questionnaire
        @new_student_level_questions = Question.new_student_level_questionnaire
        @evaluation_level_refs = EvaluationLevelRef.all

        @new_student_level_questionnaires = activity_application
                                              .user
                                              .new_student_level_questionnaires
                                              .includes(activity_ref: { activity_ref_kind: {} }, answers: {})
                                              .where(
                                                season: activity_application.season,
                                                activity_ref: activity_application.desired_activities.map(&:activity_ref),
                                              )
                                              .as_json(include: { answers: {}, activity_ref: { include: [:activity_ref_kind] } })

        @student_evaluations = {
          common_reference_data: {
            evaluation_level_refs: @levels.as_json,
          },
          forms: activity_application
                   .user
                   .student_evaluations
                   .joins(activity: { activity_ref: { activity_ref_kind: {} } })
                   .where({
                            activities: {
                              activity_refs: {
                                id: activity_application.desired_activities.map(&:activity_ref_id),
                              },
                            },
                          })
                   .map do |evaluation|
            {
              contextual_reference_data: {
                activities: evaluation
                              .teacher
                              .season_teacher_activities(evaluation.season.previous)
                              .as_json(only: %i[id group_name], include: :users),
              },
              form: evaluation.as_json({
                                         include: {
                                           teacher: {},
                                           season: {},
                                           activity: {},
                                           answers: {},
                                         },
                                       }),
            }
          end,
        }

        @application_change_questionnaires = {
          common_reference_data: {
            locations: Location.all.as_json,
          },
          forms: activity_application.user
                                     .application_change_questionnaires
                                     .includes(activity: { activity_ref: { activity_ref_kind: {} }, teachers_activities: :teacher, time_interval: {} })
                                     .where(season: activity_application.season)
                                     .map do |questionnaire|
            {
              contextual_reference_data: {},
              form: questionnaire.as_json({
                                            include: {
                                              activity: {
                                                include: {
                                                  activity_ref: { include: [:activity_ref_kind] },
                                                  time_interval: {},
                                                },
                                                methods: :teacher,
                                              },
                                              answers: {},
                                            },
                                          }),
            }
          end,
        }

        @can_edit_availabilities = Parameter.get_value("activity_applications.can_edit_availabilities") == true
      end
      format.json { render json: @activity_application }
    end
  end

  def new
    school = School.first

    @country_code = school&.address&.country || "FR"
    @school_name = school ? school.name : ""

    @season = Season.current_apps_season.as_json({ include: :holidays })

    @seasons = Season.all_seasons_cached.as_json({ include: :holidays })
    if current_user.nil?
      @current_user = nil
    else
      @current_user = current_user
      user = User.includes(planning: :time_intervals, payer_payment_terms: {})
      @user = params[:user_id] ? user.find(params[:user_id]) : user.find(current_user.id)
    end

    @pre_selected_user = params[:user_id] ? User.find(params[:user_id]) : @current_user

    # when current_user is nil and params[:user_id] is nil => cannot create inscription for nothing
    redirect_to "/" and return if @pre_selected_user.nil?

    # etant donnée que l'on récupère toutes les activity_refs pour le front
    # Autant le faire une fois pour toute et ne travailler qu'avec les activity_refs
    # Cela évite les appels multiples à la base de données et surtout de recalculer les prix à chaque fois (surtout display_prices_by_season)

    if MaxActivityRefPriceForSeason.all.empty?
      ActivityRefMaxPricesCalculatorJob.perform_now(nil)
    end

    @all_activity_refs = ActivityRef.all.includes(:activity_ref_kind, :max_prices).as_json(
      methods: [:display_name, :kind],
      include: {
        activity_ref_kind: {},
      }
    )

    activity_refs = @all_activity_refs.filter { |ar| ar["is_lesson"] || ar["is_visible_to_admin"] }
    activity_refs = activity_refs.filter { |ar| (ar["is_visible_to_admin"] || false) == false } unless current_user&.is_admin

    all_max_prices = Elvis::CacheUtils.cache_block_if_enabled("wizard:activity_ref_max_prices") do
      MaxActivityRefPriceForSeason
        .where(target_id: activity_refs.map { |a| a["id"] }.append(activity_refs.map { |a| a["activity_ref_kind_id"] }).uniq)
        .as_json
    end

    default_activity_ref_ids = @all_activity_refs
                                 .map { |ar| ar.dig("activity_ref_kind", "default_activity_ref_id") }
                                 .compact
                                 .uniq

    default_activity_prices = {}
    if default_activity_ref_ids.any?
      prices = ActivityRefPricing
                 .select("activity_ref_pricings.id, activity_ref_pricings.activity_ref_id, activity_ref_pricings.price, activity_ref_pricings.from_season_id, activity_ref_pricings.to_season_id")
                 .where(activity_ref_id: default_activity_ref_ids, deleted_at: nil)
                 .joins("inner join seasons as from_seasons on activity_ref_pricings.from_season_id = from_seasons.id")
                 .joins("left join seasons as to_seasons on activity_ref_pricings.to_season_id = to_seasons.id or activity_ref_pricings.to_season_id is null")
                 .includes(:from_season, :to_season)

      @seasons.each do |season|
        season_obj = Season.find(season["id"])
        season_start = season_obj.start

        default_activity_ref_ids.each do |activity_ref_id|
          valid_prices = prices
                           .select { |p|
                             p.activity_ref_id == activity_ref_id &&
                               p.from_season.start <= season_start &&
                               (p.to_season_id.nil? || p.to_season.end >= season_start)
                           }
                           .map(&:price)

          max_price = valid_prices.max || 0

          default_activity_prices[activity_ref_id] ||= {}
          default_activity_prices[activity_ref_id][season["id"]] = max_price
        end
      end
    end

    # do not add display_prices_by_season and display_price to @all_activity_refs.as_json
    # because this can be a huge amount of data && sql queries
    # So add them to activity_refs in a bulk operation
    def get_max_price_for_target_id(all_max_prices, target_id, target_type, season_id)
      all_max_prices
        .find { |mp|
          mp["target_type"] == target_type &&
            mp["target_id"] == target_id &&
            mp["season_id"] == season_id
        }&.dig("price")
    end

    activity_refs.each do |ar|
      ar["display_price"] = get_max_price_for_target_id(
        all_max_prices,
        ar["substitutable"] ? ar["activity_ref_kind_id"] : ar["id"],
        ar["substitutable"] ? "ActivityRefKind" : "ActivityRef",
        @season["id"]
      ) || 0

      ar["display_prices_by_season"] = @seasons.each_with_object({}) do |season, hash|
        hash[season["id"]] = get_max_price_for_target_id(
          all_max_prices,
          ar["substitutable"] ? ar["activity_ref_kind_id"] : ar["id"],
          ar["substitutable"] ? "ActivityRefKind" : "ActivityRef",
          season["id"]
        )
      end
    end

    # We want only the highest priced activity_ref for each kind
    display_activity_refs = activity_refs
                              .select { |ar| ar["activity_type"] != "child" && ar["activity_type"] != "cham" && ar["substitutable"] }
                              .group_by { |ar| ar["kind"] }
                              .transform_values do |values|
      default_id = values.first.dig("activity_ref_kind", "default_activity_ref_id")
      default_activity = default_id && values.find { |ar| ar["id"] == default_id }

      selected = default_activity || values.max_by { |ar| ar["display_price"] }

      if default_activity && default_id
        selected["display_price"] = default_activity_prices.dig(default_id, @season["id"]) || 0

        selected["display_prices_by_season"] = @seasons.each_with_object({}) do |season, h|
          h[season["id"]] = default_activity_prices.dig(default_id, season["id"]) || 0
        end
      end

      selected
    end
                              .values


    @activity_refs = display_activity_refs
                       .append(activity_refs.select { |ar| ar["activity_type"] != "child" && ar["activity_type"] != "cham" && !ar["substitutable"] })
                       .flatten
                       .sort_by { |a| a["kind"] }

    @activity_refs_childhood = activity_refs.select { |ar| ar["activity_type"] == "child" }
    @activity_refs_cham = activity_refs.filter { |ar| ar["activity_type"] == "cham" }

    @application_change_questions = Question.application_change_questionnaire.to_a
    @new_student_level_questions = Question.new_student_level_questionnaire.to_a
    @locations = Location.all.to_a
    @all_activity_ref_kinds = ActivityRefKind.all.as_json
    @last_adherent_number = User.maximum("adherent_number")
    @actionType = 0 # new application
    @instruments = Instrument.all.to_a
    @consent_docs = ConsentDocument.jsonize_consent_document_query(ConsentDocument.all.order(:index))

    show_payment_schedule_options_param = Parameter.find_or_create_by(label: "payment_terms.activated", value_type: "boolean")
    show_payment_schedule_options = show_payment_schedule_options_param.parse

    @avail_payment_schedule_options = show_payment_schedule_options ? PaymentScheduleOptions.all.as_json : []
    @avail_payment_methods = show_payment_schedule_options ? PaymentMethod.displayable.as_json(only: [:id, :label]) : []
    @payment_step_display_text = show_payment_schedule_options ? Parameter.find_or_create_by(label: "payment_step.display_text", value_type: "string").parse : ""

    @adhesion_prices = AdhesionPrice.all.as_json

    show_activity_choice_option = Parameter.get_value("activity_choice_step.activated")
    @activitychoice_display_text = show_activity_choice_option ? Parameter.get_value("activity_choice_step.display_text") : ""

    @packs = Elvis::CacheUtils.cache_block_if_enabled("activity_refs_packs:season_#{Season.current.id}") do
      ActivityRefPricing
        .joins(:pricing_category)
        .for_season_id(Season.current.id)
        .where(pricing_categories: { is_a_pack: true })
        .as_json(include: {
          pricing_category: {},
        })
    end

    @packs.each do |pack|
      pack["activity_ref"] = @all_activity_refs.find { |ar| ar["id"] == pack["activity_ref_id"] }
    end

    # on regroupe les activity_ref_pricings par label
    @packs = @packs.group_by { |arp| arp["activity_ref"]["label"] }
    # pick only the is_a_pack activity_ref_pricings
    @packs = @packs.each do |key, value|
      @packs[key] = value.select { |arp| arp["pricing_category"]["is_a_pack"] }
    end

    @availability_message = Parameter.find_by(label: 'availability_message')&.value ||
      "Sélectionner plusieurs créneaux de disponibilités, vous aurez ainsi plus de possibilités d'inscription."

    # on retire les packs qui n'ont pas de tarifs
    @packs = @packs.select { |_key, value| value.any? }

    @formules = Formule.all.as_json(
      include: {
        formule_items: { include: { item: { only: %i[id display_name] } } },
        formule_pricings: {
          only: %i[id price],
          include: {
            pricing_category: { only: %i[id name] },
            from_season: { only: %i[id name] },
            to_season: { only: %i[id name] }
          }
        }
      }
    )

    @formula_prices = @formules.map do |f|
      { id: f["id"], display_price: f["display_price"] || 0 }
    end
    # ==========================================================================

    if @current_user.nil?
      # @current_user = User.new
      # @current_user.first_connection = true
      # @hide_navigation = true
      render layout: "simple"
    end
  end


  # (pour élève/admin) pour un élève déjà inscrit et possédant une préinscription, renvoie vers le Wizard
  def new_for_existing_user
    school = School.first
    @country_code = school&.address&.country || "FR"

    @school_name = school ? school.name : ""

    @hide_navigation = false
    pre_selected_user = User.includes(planning: :time_intervals).find(params[:user_id])

    redirect_to "/401" and return unless can? :create, ActivityApplication.new(user_id: pre_selected_user.id)

    @user = pre_selected_user.as_json(include: { planning: { include: [:time_intervals] }, consent_document_users: {} }, methods: :family_links_with_user)
    @current_user = current_user

    display_activity_refs = []
    display_activity_refs_childhood = []

    if @current_user.nil?
      # @current_user = User.new
      # @current_user.first_connection = true
      # @hide_navigation = true
      render layout: "simple"
    end

    @consent_docs = ConsentDocument.jsonize_consent_document_query(ConsentDocument.all.order(:index))

    # activity_refs = ActivityRef.where({ is_lesson: true, is_visible_to_admin: false }).where.not(kind: "CHAM")
    display_activity_refs = ActivityRef
                              .includes(:activity_ref_kind)
                              .where({ is_lesson: true, is_visible_to_admin: false })
                              .where.not(activity_type: ["cham", "child"])
                              .or(
                                ActivityRef
                                  .where({ is_lesson: true, is_visible_to_admin: false })
                                  .where(activity_type: nil)
                              )
                              .to_a

    # We want all activity_refs for "Enfance" kind
    # display_activity_refs_childhood << activity_refs.select { |ar| ar.kind == "Enfance" }
    display_activity_refs_childhood = ActivityRef
                                        .includes(:activity_ref_kind)
                                        .where({ is_lesson: true, is_visible_to_admin: false, activity_type: "child" })
                                        .to_a

    # We want only the highest priced activity_ref for each kind
    # activity_refs.select { |ar| (!ar.label.include?("30") and ar.kind != "Enfance") }
    #              .group_by(&:kind)
    #              .each { |_key, values| display_activity_refs << values.max_by(&:display_price) }

    query = ActivityRef
              .includes(:activity_ref_kind)
              .where({ is_lesson: true, is_visible_to_admin: false })
              .where.not(activity_type: "child")
              .or(
                ActivityRef
                  .includes(:activity_ref_kind)
                  .where({ is_lesson: true, is_visible_to_admin: false })
                  .where(activity_type: nil)
              )

    query.to_a
         .group_by(&:kind)
         .each { |_key, values| display_activity_refs << values.max_by(&:display_price) }

    season = Season.next

    pre_application_activity = params[:pre_application_activity_id].to_i.positive? ? PreApplicationActivity.find(params[:pre_application_activity_id]) : nil

    @learned_activities = pre_selected_user
                            .activity_applications
                            .map(&:desired_activities)
                            .flatten
                            .select(&:is_validated)
                            .map(&:activity_ref_id)
                            .uniq

    @current_user_is_admin = current_user ? current_user.is_admin : false
    @activity_refs = display_activity_refs.flatten.sort_by(&:kind).as_json(methods: [:display_price, :display_name, :kind, :display_prices_by_season])
    @activity_refs_childhood = display_activity_refs_childhood.flatten.as_json(methods: [:display_price, :display_name, :kind, :display_prices_by_season])
    @all_activity_refs = ActivityRef.all.as_json(methods: [:display_price, :display_name, :kind, :display_prices_by_season])
    @all_activity_ref_kinds = ActivityRefKind.all.as_json
    @activity_refs_cham = []
    @season = season.as_json({ include: :holidays })
    @seasons = Season.all_seasons_cached.as_json({ include: :holidays })
    @application_change_questions = Question.application_change_questionnaire
    @instruments = Instrument.all
    @locations = Location.all
    @new_student_level_questions = Question.new_student_level_questionnaire
    if pre_application_activity
      @pre_application_activity = pre_application_activity.as_json({
                                                                     include: {
                                                                       activity: {
                                                                         include: {
                                                                           activity_ref: {
                                                                             include: :next_cycles,
                                                                           },
                                                                         },
                                                                       },
                                                                     },
                                                                   })
    end
    @pre_selected_activity_id = Integer(params[:activity_ref_id]) unless params[:activity_ref_id] == "0"
    @availabilities = pre_selected_user.planning.time_intervals.where({ is_validated: false,
                                                                        start: (season.start..season.end) }).as_json
    @pre_selected_user = pre_selected_user.as_json({
                                                     include: {
                                                       consent_document_users: {},
                                                       telephones: {},
                                                       planning: {},
                                                       addresses: { only: %i[id street_address country department
                                                                            postcode city] },
                                                       levels: { include: %i[evaluation_level_ref activity_ref] },
                                                       instruments: {},
                                                     },
                                                   })

    @pre_selected_user[:family_links_with_user] = pre_selected_user.family_links_with_user(season)

    if @pre_selected_user[:family_links_with_user].empty? && season.previous
      @pre_selected_user[:family_links_with_user] = pre_selected_user.family_links_with_user(season.previous)
    end

    @actionType = params[:action_type].nil? ? 0 : params[:action_type].to_i

    show_payment_schedule_options_param = Parameter.find_or_create_by(label: "payment_terms.activated", value_type: "boolean")
    show_payment_schedule_options = show_payment_schedule_options_param.parse

    @avail_payment_schedule_options = show_payment_schedule_options ? PaymentScheduleOptions.all.as_json : []
    @avail_payment_methods = show_payment_schedule_options ? PaymentMethod.displayable.as_json(only: [:id, :label]) : []
    @payment_step_display_text = show_payment_schedule_options ? Parameter.find_or_create_by(label: "payment_step.display_text", value_type: "string").parse : ""

    @availability_message = Parameter.find_by(label: 'availability_message')&.value ||
      "Sélectionner plusieurs créneaux de disponibilités, vous aurez ainsi plus de possibilités d'inscription."

    @adhesion_prices = Adhesion.all.as_json

    show_activity_choice_option = Parameter.get_value("activity_choice_step.activated")
    @activitychoice_display_text = show_activity_choice_option ? Parameter.get_value("activity_choice_step.display_text") : ""
  end

  def create

    authorize! :create, ActivityApplication.new(user_id: params[:application][:infos][:id])
    begin
      new_applications = []

      ActivityApplication.transaction do
        if params[:application][:personSelection] == "myself"
          # @type [User]
          @user = User.find(params[:application][:user][:id])
        else
          # @type [User] new user
          @user = if (params[:application][:infos][:id]).zero?
                    User.new(attached_to_id: params[:application][:infos][:attached_to_id])
                  else
                    User.find(params[:application][:infos][:id])
                  end

          # On créé un planning ici, pour pouvoir y associer les disponibilités juste après
          @user.planning = Planning.new if @user.planning.nil?
          @user.first_name = params[:application][:infos][:first_name]
          @user.last_name = params[:application][:infos][:last_name]
          @user.email = params[:application][:infos][:email]
        end

        levels = []

        params[:application][:personalLevels]&.each do |activity_ref_id, level_param|
          existing_level = Level.find_by(
            season_id: params[:application][:season_id],
            activity_ref_id: activity_ref_id,
            user_id: @user.id
          )

          # Check if the activity_ref_id exists in levelQuestionnaireAnswers
          existing_level_questionnaire = params[:application][:levelQuestionnaireAnswers].key?(activity_ref_id.to_s)

          if existing_level_questionnaire
            next
          elsif existing_level.nil?
            # If there is no questionnaire and no current level, create a new level
            new_level = Level.new(
              activity_ref_id: activity_ref_id,
              evaluation_level_ref_id: level_param,
              season_id: params[:application][:season_id]
            )
            levels << new_level
          end
        end

        @user.levels = levels unless levels.empty?

        # enregistrement du niveau de l'élève
        # parcourir chaque selected activities
        # pour chaque selected activity, créer un niveau

        # params[:application][:selectedActivities].map do |selected_id|
        #   existing_level = Level.find_by(season_id: params[:application][:season_id], activity_ref_id: selected_id, user_id: @user.id)
        #   existing_level_questionnaire = NewStudentLevelQuestionnaire.find_by(user_id: @user.id, activity_ref_id: selected_id, season_id: params[:application][:season_id])
        #
        #   # Create beginner level if user has no questionnaire and has no existing level
        #   if existing_level.nil? && existing_level_questionnaire.nil?
        #     @user.levels.find_or_create_by!(
        #       season: @season,
        #       activity_ref: @activity_ref,
        #       evaluation_level_ref: EvaluationLevelRef::DEFAULT_LEVEL_REF_ID,
        #     )
        #   end
        # end

        @user.birthday = params[:application][:infos][:birthday]
        @user.sex = params[:application][:infos][:sex]
        @user.handicap_description = params[:application][:infos][:handicap_description]
        @user.handicap = !@user.handicap_description.blank?
        @user.checked_gdpr = params[:application][:infos][:checked_gdpr]
        @user.checked_image_right = params[:application][:infos][:checked_image_right]
        @user.checked_newsletter = params[:application][:infos][:checked_newsletter]
        @user.is_paying = params[:application][:infos][:is_paying]
        @user.identification_number = if !"#{params[:application][:infos][:identification_number]}".empty?
                                        "#{params[:application][:infos][:identification_number]}"
                                      else
                                        nil
                                      end
        @user.instruments = Instrument.where(id: params.dig(:application, :infos, :instruments)&.map do |i|
          i[:id]
        end || [])

        season = Season.find(params[:application][:season_id])

        phones = []
        params[:application][:infos][:telephones]&.each do |p|
          phone = Telephone.new({ number: p[:number], label: p[:label] })
          phones << phone
        end
        @user.telephones = phones

        unless params[:application][:infos][:addresses].nil?
          @user.update_addresses params[:application][:infos][:addresses]
        end

        # cette ligne de code est à supprimer
        # dans le cadre du décommissionnement de
        # la fonctionnalité "accompagnant / additional_student"
        additional_students = params[:application][:additionalStudents]

        # enregistrement des disponibilités de l'élève
        @user.planning.update_intervals(params[:application][:intervals], season.id)

        # mise à jour de l'indicateur de paiement
        payers = params.dig(:application, :infos, :payers)
        if payers
          @user.is_paying ||= payers.any? { |p| p == @user.id }
        end

        @user.save!

        # enregistrement des consentements de l'élève
        params.dig(:application, :infos, :consent_docs)&.each do |doc|

          consentement = @user.consent_document_users.find_or_create_by(consent_document_id: "#{doc[0]}".gsub("id_", ""))

          consentement.has_consented = doc[1][:agreement]
          consentement.save!
        end

        family_links_with_user = params.dig(:application, :infos, :family_links_with_user)

        family_links_with_user&.each do |family_link|
          family_link_member = User.find_by(id: family_link[:id])&.as_json(include: {
            telephones: {},
            addresses: {}
          })

          if family_link_member.nil?
            tmp_user = User.new(
              first_name: family_link[:first_name],
              last_name: family_link[:last_name],
              email: family_link[:email],
              birthday: family_link[:birthday],
              attached_to_id: @user.id,
            )

            next unless tmp_user.save

            family_link[:id] = tmp_user.id

            tmp_user.planning = Planning.new if tmp_user.planning.nil?

            family_link_member = tmp_user.as_json(include: {
              telephones: {},
              addresses: {}
            })
          end

          family_link.merge!(family_link_member: family_link_member)

          # force values to boolean (possible values are true, false, nil)
          family_link[:is_to_call] = !!family_link[:is_to_call]
          family_link[:is_accompanying] = !!family_link[:is_accompanying]
          family_link[:is_legal_referent] = !!family_link[:is_legal_referent]
          family_link[:is_paying_for] = !!family_link[:is_paying_for]

          if family_link[:is_paying_for]
            payers << family_link[:id]
          end

          is_created = FamilyMemberUsers.addFamilyMemberWithConfirmation(
            [family_link],
            @user,
            season,
            send_confirmation: false
          )

          unless is_created
            raise "Erreur lors de la création ou mise à jour d'un lien familial (#{current_user.id} -> #{used_user.id})"
          end
        end

        # il faut que le user soit sauvegardé pour pouvoir lui associer des membres de la famille
        @user.update_is_paying_of_family_links(payers, season, false)

        if params[:application][:infos][:payer_payment_terms].present?
          existing_payment_terms = @user.payer_payment_terms.where(season_id: season.id)

          received_payment_terms = params[:application][:infos][:payer_payment_terms]&.find { |p| p[:season_id] == season.id }

          if received_payment_terms.present?
            if existing_payment_terms.empty?
              @user.payer_payment_terms.create!(
                payment_schedule_options_id: received_payment_terms.fetch(:payment_schedule_options_id, nil),
                season_id: season.id,
                day_for_collection: received_payment_terms[:day_for_collection],
                payment_method_id: received_payment_terms[:payment_method_id],
              )
            else
              existing_payment_terms.first&.update!(
                day_for_collection: received_payment_terms[:day_for_collection],
                payment_schedule_options_id: received_payment_terms[:payment_schedule_options_id],
                payment_method_id: received_payment_terms[:payment_method_id],
              )
            end
          end
        end

        default_aa_status = Parameter.find_by(label: "activityApplication.default_status")
        initial_aa_status = ActivityApplicationStatus.find(default_aa_status&.parse&.positive? ? default_aa_status.parse : ActivityApplicationStatus::TREATMENT_PENDING_ID)

        if params[:preApplicationActivityId].present? && params[:preApplicationActivityId] != "0" #  == "Change"
          pre_application_activity = PreApplicationActivity.find(params[:preApplicationActivityId])
        end

        if params[:application][:applicationChangeAnswers].keys.size.positive?
          ApplicationChangeQuestionnaires::CreateWithAnswers
            .new(
              @user,
              pre_application_activity.activity,
              season,
              params[:application][:applicationChangeAnswers]
            )
            .execute
        end




        formula_activities = params[:application][:selectedFormulaActivities] || {}

        params[:application][:selectedActivities].each do |act|
          # Création de l'inscription
          @activity_application = ActivityApplication.create!(
            user: @user,
            activity_application_status: initial_aa_status,
            season: season,
            begin_at: params[:application][:begin_at] || season.start,
            )


          formula_id = nil
          formula_activities.each do |formula_id_key, activities|
            if activities.include?(act.to_s) || activities.include?(act)
              formula_id = formula_id_key
              break
            end
          end


          if formula_id
            @activity_application.update(formule_id: formula_id)
          end

          # Ajout, à l'inscription, des activités souhaitées
          #  Here, additionalStudenst are indexed incrementaly by their position in family, because they may not be already created
          @activity_application.add_activities([act], additional_students, @user.family)

          # Ajout des commentaires à l'inscription
          unless params[:application][:comment].blank?
            content = params[:application][:comment].strip
            @activity_application.comments << Comment.new(user_id: params[:application][:user][:id], content: content)
          end

          # If the user come from the pre_application, we need to flag the pre_application_activity as done
          # unless params[:preApplicationActivityId].nil?
          possible_actions = %w[
            new
            renew
            change
            stop
            pursue_childhood
            cham
          ]

          pre_application = PreApplication.find_by(user_id: @user.id)
          if pre_application.nil?
            pre_application = @user.pre_applications.create!(
              user: @user,
              season: season,
            )
          end

          if pre_application_activity.present?
            # act.to_i == pre_application_activity.activity.activity_ref_id
            pre_application_activity.status = true
            pre_application_activity.action = possible_actions[params[:actionType].to_i]
            pre_application_activity.activity_application = @activity_application

            pre_application_activity.save
          else
            pre_application_desired_activity = PreApplicationDesiredActivity.create!(
              desired_activity: @activity_application.desired_activities.last,
              pre_application: pre_application,
              activity_application: @activity_application,
            )
          end

          # Preferences for kind "Enfance"
          params[:application][:childhoodPreferences][act.to_s]&.each_with_index do |ti, index|
            TimeIntervalPreference.create({
                                            user_id: @user.id,
                                            season_id: season.id,
                                            time_interval_id: ti[:id],
                                            activity_ref_id: act,
                                            activity_application_id: @activity_application.id,
                                            rank: index,
                                          })
          end

          if params[:application][:levelQuestionnaireAnswers][act.to_s]
            activity_ref = ActivityRef.find(act)
            NewStudentLevelQuestionnaires::CreateWithAnswers
              .new(
                @user,
                activity_ref,
                season,
                params[:application][:levelQuestionnaireAnswers][act.to_s]
              )
              .execute
          end

          new_applications << @activity_application
        end

        # This means that the user should have
        if params[:application][:practicedInstruments].any? && params[:application][:selectedEvaluationIntervals]
          params[:application][:selectedEvaluationIntervals].each do |ref_id, interval|
            activity_ref = ActivityRef.find(ref_id)

            evaluation_interval = nil
            teacher = nil

            next if interval.blank?

            evaluation_interval = TimeInterval.evaluation.find(interval[:id])
            teacher = evaluation_interval.teacher
            @activity_application.update!(activity_application_status: ActivityApplicationStatus.find(ActivityApplicationStatus::ASSESSMENT_PENDING_ID))

            # only assign student if an evaluation interval is selected
            EvaluationAppointments::AssignStudent.new(
              evaluation_interval,
              @user,
              @activity_application
            )
                                                 .execute
          end
        end

        formules_ids = params[:application][:selectedFormulas] || []
        formula_activities = params[:application][:selectedFormulaActivities] || {}
        unless formules_ids.empty?
          @activity_application.update(formule_id: formules_ids.first)
        end

        @pack_created = false
        unless params[:application][:selectedPacks].empty?
          params[:application][:selectedPacks].each do |key, value|
            pc = PricingCategory.find(value).first
            activity_ref_pricing = nil
            pc.activity_ref_pricing.each do |arp|
              activity_ref_pricing = arp if arp.activity_ref.label == key
            end

            Pack.create!(user_id: @user.id, activity_ref_pricing_id: activity_ref_pricing.id, season_id: season.id, lessons_remaining: pc.number_lessons)
            @pack_created = true
          end
        end

        @user.save!
      end

      begin
        # notify new users of their new application
        new_applications.each do |app|
          EventHandler.notification.application_created.trigger(
            sender: {
              controller_name: self.class.name,
            },
            args: {
              activity_application_id: app.id
            }
          )
        end

      rescue StandardError => e
        Rails.logger.error "#{e.message}\n#{e.backtrace&.join("\n")} "

        creator = User.find_by(is_creator: true)

        if creator.present? && Parameter.get_value("app.notify_wizard_error") == true
          MessageMailer.with(message: {
            title: "Notification d'erreur dans le wizard d'inscription",
            content: "#{e.message}\n#{e.backtrace&.join("\n")} ",
            isSMS: false,
            isEmail: true
          }.as_json, to: creator.id.to_s, from: User.new(email: Parameter.get_value("app.application_mailer.default_from"), id: 0)).send_message.deliver_later
        end

        Sentry.capture_exception(e)
      end

      render json: {
        success: true,
        activity_application: @activity_application,
        pack_created: @pack_created,
      }
    rescue IntervalTakenError => e
      render status: 400, json: { errors: [e.message] }
    rescue StandardError => e
      Rails.logger.error "#{e.message}\n#{e.backtrace&.join("\n")} "

      creator = User.find_by(is_creator: true)

      if creator.present? && Parameter.get_value("app.notify_wizard_error") == true
        MessageMailer.with(message: {
          title: "Notification d'erreur dans le wizard d'inscription (non-catcher)",
          content: "#{e.message}\n#{e.backtrace&.join("\n")}",
          isSMS: false,
          isEmail: true
        }, to: User.where(id: creator.id, from: User.new(email: Parameter.get_value("app.application_mailer.default_from")))).send_message.deliver_later
      end

      render status: 500, json: {
        errors: ["Une erreur est survenue lors de la création de votre demande d'inscription, veuillez-contacter l'administration."],
      }
    end
  end

  def create_import_csv
    raise CanCan::AccessDenied unless current_user&.is_admin

    handler_class_name = case Parameter.get_value('activity_applications.importer_name')
                         when 'tes_importer'
                           "ActivityApplications::TesImportHandler"
                         else
                           nil
                         end

    render json: { error: "L'import de fichier d'inscriptions est désactivé" }, status: :unprocessable_entity and return if handler_class_name.nil?

    begin

      # save file to file with GUID as filename
      file_path = 'tmp/' + SecureRandom.uuid
      file_content = File.binread(params[:file].path).force_encoding('UTF-8')
      File.write(file_path, file_content)

      job = CsvImporterJob.perform_later(file_path, handler_class_name)

    rescue StandardError, NoMemoryError => e
      render json: { errors: e }, status: 500
      return
    end

    render json: { jobId: job.job_id }
  end

  def bulk_update
    query = get_query_from_params params[:filter]

    entries = if params[:targets] == "all"
                query
              else
                ActivityApplication.where(id: params[:targets])
              end

    entries.find_each(batch_size: 200) do |entry|
      raise CanCan::AccessDenied unless can? :edit, entry
    end

    edit_params = bulk_edit_application_params

    edit_params[:status_updated_at] = Time.now if edit_params[:activity_application_status_id]

    entries.update_all(edit_params.to_h)

    respond_to do |format|
      format.json { render json: applications_list_json(query, params[:filter]) }
    end
  end

  def send_confirmation_mail
    application = ActivityApplication.includes(desired_activities: :activity).find(params[:id])

    authorize! :edit, application

    user = application.user

    application.desired_activities.each do |da|
      activity = da.activity

      # mail
      case params[:application_status]
      when ActivityApplicationStatus::ACTIVITY_ATTRIBUTED_ID
        ActivityAssignedMailer.activity_assigned(user, user.confirmation_token, application, activity).deliver_later
      when ActivityApplicationStatus::ACTIVITY_PROPOSED_ID
        ActivityProposedMailer.activity_proposed(user, user.confirmation_token, application, activity).deliver_later
      end
    end


    application.mail_sent = true
    application.save
  end

  def send_all_confirmation_mail
    filter = params[:filter]

    filtered_season_id = filter&.dig(:filtered)&.find { |f| f[:id] == "season_id" }&.dig(:value)

    season = filtered_season_id.nil? || filtered_season_id == "all" ? Season.current_apps_season : Season.find(filtered_season_id)

    if params[:targets].length == 0
      render json: { success: false, message: "Vous n'avez pas selectionné d'utilisateurs" }, status: 400 and return
    end

    # get same query from user view
    query = get_query_from_params filter

    # if we have selected some users, add them to the query filter
    if params[:targets] != "all"
      query = query.where(id: params[:targets])
    end

    # force filter to only send email to user with good status AND in the current season if no season is selected
    mails_to_send = query.where(
      activity_application_status_id: [ActivityApplicationStatus::ACTIVITY_ATTRIBUTED_ID, ActivityApplicationStatus::ACTIVITY_PROPOSED_ID, ActivityApplicationStatus::PROPOSAL_ACCEPTED_ID],
      season_id: season.id
    )

    force_resend = params[:forceResend] == 1
    unless force_resend
      mails_to_send = mails_to_send.where(mail_sent_at: nil)
    end

    mails_to_send.find_each(batch_size: 500) do |application|
      raise CanCan::AccessDenied unless can? :manage, application
    end

    if mails_to_send.length == 0
      render json: { success: false, message: "Les utilisateurs selectionnés ont déjà reçu le mail ou ne sont pas en cours attribué / cours proposé" }, status: 400 and return
    end

    NotifyUsersOfApplicationStateJob.perform_later(applications_ids: mails_to_send.ids, current_user_id: current_user.id)

    render json: { success: true }, status: 200
  end

  # (pour élèves) demande d'inscription pour renouveler l'activité
  def renew
    activity_application = ActivityApplication
                             .joins(:desired_activities)
                             .where({
                                      user_id: params[:user_id],
                                      season: Season.current,
                                      desired_activities: {
                                        activity_ref_id: params[:activity_ref_id],
                                      },
                                    }).first

    authorize! :edit, activity_application

    next_season = Season.next
    default_status = ActivityApplicationStatus.find(ActivityApplicationStatus::TREATMENT_PENDING_ID)

    new_activity_application = activity_application.deep_clone include: [:desired_activities]
    new_activity_application.desired_activities.each do |da|
      da.activity_id = nil
      da.is_validated = false
    end
    new_activity_application.season = next_season

    new_activity_application.desired_activities = new_activity_application.desired_activities.select do |da|
      da.activity_ref_id == params[:activity_ref_id]
    end
    new_activity_application.activity_application_status = default_status
    new_activity_application.save

    # We need to create or dup or convert the availabilities of the student
    # to show the correct suggestions
    time_interval = activity_application.desired_activities.select do |da|
      da.activity_ref_id == params[:activity_ref_id]
    end.first.activity.time_interval
    activity_application.user.planning.create_availability(time_interval)

    pre_application_activity = PreApplicationActivity.find(params[:pre_application_activity_id])
    pre_application_activity.activity_application = new_activity_application
    pre_application_activity.save

    EventHandler.notification.application_created.trigger(
      sender: {
        controller_name: self.class.name,
      },
      args: {
        activity_application_id: new_activity_application.id
      }
    )

    render json: new_activity_application.as_json(include: {
      desired_activities: {},
      activity_application_status: {},
      # :activities => {
      #   include: {
      #     :activity_ref => {}
      #   }
    })
  end

  def destroy
    activity_application = ActivityApplication.find(params[:id])

    authorize! :destroy, activity_application

    handle_related_records(activity_application)
    activity_application.destroy
  end

  def bulk_delete
    targets = params[:targets]

    if targets == "all"
      targets = ActivityApplication
                  .joins(:activity_application_status)
                  .where(activity_application_status: { id: ActivityApplicationStatus::TREATMENT_PENDING_ID })
                  .pluck(:id)
    end

    if targets.blank? || (!targets.is_a?(Array) && targets != "all")
      render json: { error: "Invalid targets" }, status: :unprocessable_entity and return
    end

    restricted_statuses = [
      ActivityApplicationStatus::ACTIVITY_ATTRIBUTED_ID,
      ActivityApplicationStatus::ACTIVITY_PROPOSED_ID,
      ActivityApplicationStatus::PROPOSAL_ACCEPTED_ID
    ]

    ActiveRecord::Base.transaction do
      activities_application = ActivityApplication.where(id: targets)
      activities_application.each do |activity_application|
        if restricted_statuses.include?(activity_application.activity_application_status_id)
          raise ActiveRecord::Rollback, "Les demandes dont le statut sont : proposition acceptée, cours proposé et cours attribué, ne peuvent être supprimées."
        end

        raise CanCan::AccessDenied unless can? :destroy, activity_application

        handle_related_records(activity_application)
      end

      activities_application.destroy_all
    end

    render json: { success: true }, status: :ok
  rescue ActiveRecord::Rollback => e
    render json: { error: e.message }, status: :forbidden
  rescue CanCan::AccessDenied
    render json: { error: 'Non autorisé' }, status: :forbidden
  end

  def find_activity_suggestions
    desired_activity_id = params[:des_id]
    do_format = params[:format] || true
    suggestions_mode = params[:mode] || "CUSTOM"

    render json: ActivityApplications::FindActivitySuggestions.new(desired_activity_id, do_format,
                                                                   suggestions_mode).execute
  end

  def add_comment
    application = ActivityApplication.includes(comments: [:user]).find(params[:id])

    authorize! :edit, application

    content = params[:comment]

    application.comments << Comment.new(user_id: current_user.id, content: content)

    application.save!

    render json: application.comments, include: [:user]
  end

  def edit_comment
    content = params[:comment][:content]

    application = ActivityApplication.includes(comments: [:user]).find(params[:id])

    authorize! :edit, application

    Comment.find(params[:comment_id]).update(content: content)

    render json: application.comments, include: [:user]
  end

  def add_activity
    activity_ref_id = params[:activity_ref_id]
    activity_application = ActivityApplication.includes(:desired_activities).find(params[:id])

    authorize! :edit, activity_application

    activity_application.add_activity(activity_ref_id)

    render json: activity_application.desired_activities
  end

  def add_activities
    activity_application = ActivityApplication.includes(:desired_activities).find(params[:id])

    authorize! :edit, activity_application

    # Here, additionalStudents are indexed on their own id, because they already exists unless additional_students.nil?

    activity_application.add_activities(params[:activity_ref_ids], params[:additionalStudents],
                                        activity_application.user.family)

    render json: activity_application.desired_activities, include: [:user]
  end

  def remove_activity
    activity_id = params[:activity_ref_id]

    activity_application = ActivityApplication.includes({ desired_activities: [:user] }).find(params[:id])

    authorize! :edit, activity_application

    activity_application.remove_desired_activity_by_id(activity_id)

    render json: activity_application.desired_activities, include: [:user]
  end

  def update
    activity_application = ActivityApplication.find(params[:id])

    authorize! :edit, activity_application

    ActivityApplication.transaction do
      p = application_update_params
      old_begin_at = activity_application.begin_at if p[:begin_at]

      activity_application.update(p)
      activity_application.save!

      if p[:begin_at]
        if activity_application.begin_at > old_begin_at
          unregisterer = ActivityApplications::UnregisterStudentFromActivityInstances.new(activity_application, old_begin_at, activity_application.begin_at - 1.day)
          unregisterer.execute
        end
      end

      # si l'inscription est validée et qu'on a décalé la date de début d'inscription, il faut mettre à jour les participations aux séances
      activity_application.desired_activities.each do |des|
        if des&.is_validated && p[:begin_at]
          if activity_application.begin_at <= old_begin_at
            registerer = Activities::RegisterStudentToActivityInstances.new(des.activity.id, des.id, false, activity_application.begin_at, old_begin_at.to_date - 1.day)
            registerer.execute
          end
        end
        # On supprime les participations aux séances si l'inscription prend fin
        DuePayments::StopActivity.new(activity_application).execute if activity_application.stopped_at

        if des.activity
          # Enfin, on actualise le nombre de séances dues par l'utilisateur (parce qu'il n'a pas commencé en début de saison/terminé en fin de saison)
          user_id = activity_application.user.id
          des.update(
            prorata: des.activity.calculate_prorata_for_student(user_id)
          )
        end
      end
    end

    # Création du trigger d'envoi de mail lorsque le statut de l'inscription passe à "Proposition acceptée"
    if activity_application.activity_application_status_id == ActivityApplicationStatus::PROPOSAL_ACCEPTED_ID
      desired_activities = ActivityApplication.find(activity_application.id).desired_activities

      desired_activities.each do |da|

        EventHandler.notification.activity_accepted.trigger(
          sender: {
            controller_name: self.class.name,
          },
          args: {
            user: User.find(activity_application.user.id),
            activity: da.activity
          }
        )
      end

    end

    activity_application.reason_of_refusal = params[:reason_of_refusal]
    activity_application.reason_of_refusal = "non spécifiée" if params[:reason_of_refusal] == ""
    activity_application.save!

    render json: activity_application.as_json(include: {
      activity_application_status: {},
      referent: {},
    })
  end

  def get_activity_application_parameters
    auto_assign_param = Parameter.find_by(label: "activityApplication.automatic_status")


    auto_assign_enabled = auto_assign_param&.value == "true"

    render json: {
      defaultActivityApplicationStatus: ActivityApplicationStatus.find(
        Parameter.get_value("activityApplication.default_status") || ActivityApplicationStatus::TREATMENT_PENDING_ID
      ),
      activityApplicationStatusList: ActivityApplicationStatus.all.as_json(except: %i[created_at updated_at]),

      autoAssignEnabled: auto_assign_enabled
    }
  end

  def set_activity_application_parameters
    status = Parameter.find_or_create_by(
      label: "activityApplication.default_status",
      value_type: "integer"
    )

    authorize! :edit, status

    status.value = params[:default_status_id]
    res = status.save


    auto_assign_param = Parameter.find_or_create_by(
      label: "activityApplication.automatic_status",
      value_type: "boolean"
    )

    authorize! :edit, auto_assign_param

    new_value = ActiveModel::Type::Boolean.new.cast(params[:auto_assign_enabled]).to_s

    auto_assign_param.value = new_value
    auto_assign_res = auto_assign_param.save


    res = res && auto_assign_res

    respond_to do |format|
      format.json { render json: { success: res } }
    end
  end

  private

  def handle_related_records(activity_application)
    activity_application.desired_activities.each do |da|
      Activity.find(da.activity_id).remove_student(da.id) if da.is_validated
      additional_student = AdditionalStudent.find_by(desired_activity_id: da.id)
      additional_student&.delete
    end

    activity_application.pre_application_activity&.reset
  end

  def application_update_params
    params.require(:application).permit(:activity_application_status_id, :referent_id, :stopped_at, :begin_at)
  end

  # corrigé ?
  def user_params
    params.require(:application).permit(
      :redirect,
      :selected_activity,
      :solfege,
      :intervals,
      :teachers,
      :locations,
      :misc,
      user: %i[id email levels],
      infos: %i[
        adhelrent_number
        birthday
        sex
        street_address
        postal_code
        city
        department
        country
        home_phone
        mobile_phone
        job
        school
        miscellaneous
        handicap
        handicap_description
      ],
    )
  end

  def bulk_edit_application_params
    params.require(:application).permit(:activity_application_status_id, :status_updated_at)
  end

  def get_query_from_params(json_query = params)
    query = ActivityApplication.all
                               .includes(:activity_refs, :user, :season)

    json_query[:filtered].each do |filter|
      prop = filter[:id]
      val = filter[:value]
      if prop == "activity_ref_id"
        if val != "all"
          query = query
                    .joins(:activity_refs => :activity_ref_kind)
                    .where({ activity_refs: {
                      label: val,
                    } })
        end
      elsif prop == "activity_ref_kind_id"
        if val != "all"
          query = query
                    .joins(:activity_refs => :activity_ref_kind)
                    .where({ activity_refs: { activity_ref_kinds: { name: val } } })
        end
      elsif prop == "activity_application_status_id"
        query = query.where(activity_application_status_id: val)
      elsif ([prop] & %w[id season_id]).any?
        query = query.where("activity_applications.#{prop} = ?", val) if val.match?(/\d+/)
      elsif prop == "age"
        query = query.joins(:user).where("FLOOR(extract(year from age(users.birthday))) = ?", val)
      elsif prop == "nb_availabilities"
        query = query.joins(desired_activities: { activity_ref: { activity_ref_kind: {} } }, user: {}, season: {})
                     .where("CASE activity_ref_kinds.is_for_child
                  WHEN true THEN
                    (SELECT COUNT(*) FROM time_interval_preferences WHERE activity_application_id = activity_applications.id) = :v
                  ELSE
                    (SELECT COUNT(*) FROM time_intervals
                    JOIN time_slots ON time_slots.time_interval_id = time_intervals.id
                    JOIN plannings ON plannings.id = time_slots.planning_id
                    WHERE plannings.user_id = users.id AND
                    time_intervals.is_validated = false
                    AND time_intervals.start BETWEEN seasons.start AND seasons.end) = :v
                  END", v: val)
      elsif prop == "level"
        query = query.joins({ user: {}, activity_refs: {} }).where("
                (SELECT MIN(l.evaluation_level_ref_id) FROM levels l
                  WHERE l.user_id = users.id
                  AND l.activity_ref_id = activity_refs.id
                  AND l.season_id = activity_applications.season_id) = ?", val)
      elsif prop == "action"
        non_new_actions = val.reject { |v| v == "new" }

        query = query
                  .joins("LEFT OUTER JOIN pre_application_activities AS paa ON paa.activity_application_id = activity_applications.id")
                  .joins("LEFT OUTER JOIN pre_application_desired_activities AS pada ON pada.activity_application_id = activity_applications.id")
                  .where("pada.action IN (:non_new_actions) OR paa.action IN (:non_new_actions) OR ('new' IN (:actions) AND (pada.action = 'new' OR (pada.id ISNULL AND paa.id ISNULL)))", {
                    actions: val,
                    non_new_actions: non_new_actions,
                  })
      elsif prop == "adherent_number"
        query = query.joins(:user).where("users.adherent_number = ?", val)
      elsif prop == "referent_id"
        query = query.where(referent_id: val)
      elsif prop == "name"
        query = query.joins(:user).where(
          "translate(trim(users.first_name || ' ' || users.last_name), '-éàçäëïöüâêîôû''', ' eacaeiouaeiou') ILIKE translate(?, '-éàçäëïöüâêîôû''', ' eacaeiouaeiou')", "%#{val}%"
        )
      elsif prop == "mail_sent"
        if val != "all"
          if val == "true"
            query = query.where.not(mail_sent_at: nil)
          elsif val == "false"
            query = query.where(mail_sent_at: nil)
          end
        end
      end
    end

    unless current_user&.is_admin

      user_activity_ref_ids = current_user.activity_refs.pluck(:id)

      query = query.where(season_id: Season.current_apps_season.id)
      query = query.joins(:desired_activities)
                   .where(desired_activities: { activity_ref_id: user_activity_ref_ids })

      #query = query.accessible_by(current_ability)
    end

    unless json_query[:sorted].nil?
      order_string = nil
      dir = json_query[:sorted][:desc] ? "desc" : "asc"

      case json_query[:sorted][:id]
      when "id"
        order_string = "activity_applications.id #{dir}"
      when "name"
        order_string = "users.first_name || ' ' || users.last_name #{dir}"
      when "date"
        order_string = "activity_applications.created_at #{dir}"
      when "adherent_number"
        order_string = "users.adherent_number #{dir}"
      when "age"
        order_string = "extract(year from age(users.birthday)) #{dir}"
        query = query.joins(:user)
      when "level"
        order_string = "(SELECT MIN(l.evaluation_level_ref_id) FROM levels l
                WHERE l.user_id = users.id
                AND l.activity_ref_id = activity_refs.id
                AND l.season_id = activity_applications.season_id) #{dir}"
        query = query.joins({ user: {}, activity_refs: {} })
      when "referent_id"
        order_string = "referent_id #{dir}"
      end

      order_sql = Arel.sql(order_string)
      query = query.order(order_sql)
    end

    query
  end

  def applications_list_json(query, filter = params)
    total = query.count

    pending_total = query
                      .joins(:activity_application_status)
                      .where(activity_application_statuses: { id: ActivityApplicationStatus::TREATMENT_PENDING_ID })
                      .count

    paginated = query.page(filter[:page] + 1)
                     .per(filter[:pageSize])
    pages = paginated.total_pages

    activity_applications = paginated.to_a

    activity_applications.each do |app|
      raise Cancan::AccessDenied unless can? :read, app
    end

    applications = activity_applications.as_json(
      include: {
        activity_refs: { only: %i[id label kind] },
        user: {
          only: %i[first_name last_name adherent_number birthday],
          include: {
            levels: { include: { evaluation_level_ref: {} } }
          }
        },
        pre_application_activity: { only: [:action] },
        pre_application_desired_activity: { only: [:action] },
        season: {},
        referent: {}
      },
      methods: :availabilities
    )

    response = {
      applications: applications,
      pages: pages,
      total: total,
      pending_total: pending_total
    }

    Rails.logger.info("Réponse JSON : #{response.to_json}")
    response
  end


  def applications_list_csv(query)
    authorize! :read, query.select(:id, :season_id, :desired_activity_id)

    CSV.generate nil, col_sep: ";" do |csv|
      csv << [
        "N° demande",
        "Activité.s",
        "Niveau",
        "Action",
        "Statut",
        "Saison",
        "N° adhérent de l'élève",
        "Nom de l'élève",
        "Prénom de l'élève",
        "Âge de l'élève",
        "Adresse mail de l'élève",
        "Adresse postale de l'élève",
        "N° de téléphone de l'élève",
        "Prénom du responsable légal",
        "Nom du responsable légal",
        "N° de téléphone du responsable légal",
        "Disponibilités",
        "Commentaires",
      ]

      s_for_links = Season.current_apps_season

      query
        .includes({
                    season: {},
                    activity_application_status: {},
                    pre_application_desired_activity_csv: {},
                    pre_application_activity_csv: {},
                    desired_activities_csv: :activity_ref,
                    comments_csv: :user,
                    user: {
                      telephones_csv: {},
                      planning_csv: {
                        time_intervals_csv: {},
                      },
                      levels_csv: {
                        activity_ref: {},
                        evaluation_level_ref: {},
                      },
                      addresses_csv: {},
                      inverse_family_members: {
                        season: {},
                        user: {
                          telephones_csv: {},
                        },
                      },
                      family_member_users: {
                        season: {},
                        member: {
                          telephones_csv: {},
                        },
                      },
                    },
                  })
        .find_each(batch_size: 1000) do |app|
        activity_refs = app
                          .desired_activities_csv
                          .map(&:activity_ref)
                          .compact

        activities = activity_refs
                       .map(&:label)
                       .join(", ")

        action = if app.pre_application_desired_activity_csv
                   if app.pre_application_desired_activity_csv.action == "change"
                     "Changement"
                   else
                     "Nouvelle demande"
                   end
                 elsif app.pre_application_activity_csv
                   if app.pre_application_activity_csv.action == "renew"
                     "Renouvellement"
                   else
                     "Changement"
                   end
                 else
                   "Nouvelle demande"
                 end

        user = app.user

        telephone = user && (user.telephones_csv.select do |t|
          t.label == "portable"
        end.first || user.telephones_csv.first)

        user_telephone_number = telephone&.number || "?"

        levels = user
                   &.levels_csv
                   &.select { |l| l.season_id == app.season_id && activity_refs.include?(l.activity_ref) }
                   &.map do |level|
          level_activity = level&.activity_ref
          level_activity = level_activity&.label || "?"

          level_label = level&.evaluation_level_ref
          level_label = level_label&.label || "?"

          "#{level_label} (#{level_activity})"
        end

        levels = levels&.any? ? levels.join(", ") : "?"

        availabilities = user
                           .planning_csv
                           .time_intervals_csv
                           .select { |ti| !ti.is_validated && ti.start && ti.end }
                           .map do |ti|
          "#{I18n.l(ti.start,
                    format: "%a")} #{ti.start.strftime "%H:%M"} ➝ #{ti.end.strftime "%H:%M"}"
        end
                           .join(", ")

        comments = app
                     .comments_csv
                     .map { |c| "« #{c.content} » (de #{c.user.first_name} #{c.user.last_name})" }
                     .join(", ")

        address = user.addresses_csv[0]
        address = address && "#{address.street_address} #{address.postcode} #{address.city&.upcase}" || "?"

        legal_referent = user.family_links(s_for_links).select(&:is_legal_referent)[0]
        legal_referent &&= (legal_referent.user_id == user.id ? legal_referent.member : legal_referent.user)

        legal_referent_telephone = legal_referent && (legal_referent.telephones_csv.select do |t|
          t.label == "portable"
        end.first || legal_referent.telephones_csv.first)
        legal_referent_telephone_number = legal_referent_telephone&.number || "?"

        csv << [
          app.id,
          activities,
          levels,
          action,
          app.activity_application_status&.label || "?",
          app.season&.label || "?",
          user && app.user.adherent_number,
          user && app.user.last_name,
          user && app.user.first_name,
          user.birthday && user.age || "?",
          user && app.user.email,
          address,
          user_telephone_number,
          legal_referent&.first_name,
          legal_referent&.last_name,
          legal_referent_telephone_number,
          availabilities,
          comments,
        ]
      end
    end
  end
end


def check_terminal_status
  query = get_query_from_params

  # Vérifie si une des demandes a un statut terminal
  has_terminal_status = query.exists?(
    activity_application_status_id: [
      ActivityApplicationStatus::ACTIVITY_ATTRIBUTED_ID,
      ActivityApplicationStatus::ACTIVITY_PROPOSED_ID,
      ActivityApplicationStatus::PROPOSAL_ACCEPTED_ID
    ]
  )

  render json: { hasTerminalStatus: has_terminal_status }
end