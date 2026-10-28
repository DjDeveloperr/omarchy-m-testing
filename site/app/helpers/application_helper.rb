module ApplicationHelper
  def nav_link(label, path)
    current = current_page?(path) || (path != root_path && request.path.start_with?(path))
    link_to label, path, class: ("current" if current), "aria-current": ("page" if current)
  end

  # A terminal card: a bordered box with its title set into the top border.
  def card(title = nil, klass: nil, id: nil, &block)
    tag.section(class: [ "card", klass ].compact.join(" "), id:) do
      safe_join([ (tag.h2(title, class: "card-title") if title), capture(&block) ].compact)
    end
  end

  def state_badge(state, label: ResultState.words(state))
    tag.span(label, class: "badge badge-#{state}")
  end

  def outcome_badge(outcome)
    tag.span(Catalogue.outcome_words(outcome), class: "badge badge-#{ResultState.for_outcome(outcome)} outcome outcome-#{outcome}")
  end

  # A check's outcome badge; a yes the human gave by pressing Enter reads "works (unconfirmed)", uncoloured.
  def check_outcome_badge(check)
    outcome = check.dig("classification", "outcome")
    return outcome_badge(outcome) unless Report.answered_by_default?(check)

    tag.span("#{Catalogue.outcome_words(outcome)} (unconfirmed)", class: "badge badge-unconfirmed outcome outcome-#{outcome} answered-by-default",
                                                                  title: "Answered by pressing Enter (the default), not a typed y: not counted in the matrix")
  end

  # One matrix cell: a coloured square once machines agree or a tester confirms, an outlined hint while unconfirmed.
  # context: the lines that place it (model, stack, feature) for its tooltip (result_tooltip).
  def matrix_cell(cell, feature_id:, link: nil, provenance: false, context: [])
    glyph = ResultState.glyph(cell.display_state)
    title = cell.summary
    data = { feature: feature_id, state: cell.hidden? ? "hidden" : cell.state || "unconfirmed", verified: ("tester" if cell.tester?) }
    details = []
    if provenance && (sources = cell.sources).any?
      kernels = sources.map(&:kernel).uniq
      title += " · kernels: #{kernels.join(', ')} · latest tested upload: #{uploaded_at(sources.first)}"
      data.merge!(kernels:, tested_at: sources.first.created_at.utc.iso8601)
      details << "Last tested #{uploaded_at(sources.first)} · kernel #{kernels.join(', ')}"
    end
    content = link && cell.reports.any? ? link_to(glyph, link, "aria-label": title) : glyph
    tooltip = result_tooltip(cell, heading: context.first, lines: context.drop(1) + details, klass: "cell-tooltip")
    tag.td(safe_join([ content, tooltip ]), class: [ cell.css_class, "has-tooltip" ], title:, data:)
  end

  # A result's tooltip: what its colour means, in that colour, how sure it is, then where it's from.
  def result_tooltip(cell, heading: nil, lines: [], klass: nil)
    state = cell.display_state
    tag.span(class: [ "result-tooltip", klass ], "aria-hidden": true) do
      safe_join([
        tag.span(class: "tooltip-verdict badge-#{state}") do
          safe_join([ tag.span(ResultState.glyph(state), class: "swatch #{cell.css_class.delete_prefix("cell ")}"), " ", ResultState.meaning(state).upcase_first ])
        end,
        tag.span(result_confidence(cell)),
        (tag.strong(heading) if heading),
        *lines.map { |line| tag.span(line, class: "dim") }
      ].compact)
    end
  end

  # How sure a result is, in plain words: tester-verified, agreed, or outlined until it's confirmed.
  def result_confidence(cell)
    if cell.hidden? then "Unconfirmed, hidden by the confirmed-only filter."
    elsif cell.tallies.empty? then "No run tested it."
    elsif cell.tester? then "Solid: verified by #{pluralize(cell.tester_machines, "tester machine")}."
    elsif cell.confirmed? then "Solid: #{pluralize(cell.machines, "machine")} agree."
    else
      "Outlined: unconfirmed. #{cell.machines == 1 ? "Only 1 machine has" : "#{cell.machines} machines have"} reported this; " \
        "it fills in once #{MatrixCell::AGREEMENT} machines agree or a tester confirms."
    end
  end

  # A feature result in a few words: the machines' states, and whether a tester verified them or they're unconfirmed.
  def feature_result_words(cell)
    return "unconfirmed, hidden" if cell.hidden?
    return "not tested" if cell.tallies.empty?

    cell.counts + (cell.tester? ? " · tester-verified" : cell.unconfirmed? ? " · unconfirmed" : "")
  end

  # A catalogue state ("upstream 6.2", "linux-asahi", "supported 7.1.12") for one layer.
  def expected_words(state)
    return "–" if state.nil?

    [ state["status"], state["version"] ].compact.join(" ")
  end

  def expected_class(layer, state)
    status = state&.fetch("status", nil)
    good = case layer
    when "asahi" then Catalogue::ASAHI_SUPPORTED.include?(status)
    else %w[supported asahi].include?(status)
    end
    return "expected expected-none" if status.nil? || status == "absent"

    good ? "expected expected-yes" : "expected expected-no"
  end

  # A report's origin: a tester run (a signed-in, allowlisted tester's machine) or a community report.
  def run_badge(report, long: false)
    if report.tester?
      tag.span(long ? "tester run" : "tester", class: "badge badge-tester",
               title: "From a tester's machine: it signed in with GitHub and the tester is on the allowlist. Tester runs colour the matrix on their own.")
    else
      tag.span(long ? "community report" : "community", class: "badge badge-community",
               title: "Uploaded anonymously. It shows here right away, and counts toward the matrix once another machine agrees or a tester confirms.")
    end
  end

  # The admin's one-click prefilled GitHub issue (IssueDraft), opened in a new tab; nothing for anyone else.
  def issue_link(draft)
    return unless admin?

    link_to "open issue on #{draft.repo}", draft.url, class: "issue-link", target: "_blank", rel: "noopener noreferrer",
                                                    title: draft.title, data: { repo: draft.repo }
  end

  def report_link_for = ->(report) { report_url(report) }

  def uploaded_at(report) = report.created_at.utc.strftime("%Y-%m-%d %H:%M UTC")

  def check_section(check_id) = check_id.split(".").first

  # A check's status as it reads: PASS, FAIL, SKIP, or GAP / N/A for a failure the catalogue expects on this Mac.
  def status_label(check)
    return check["status"].upcase unless Report.expected_gap?(check)

    check.dig("classification", "outcome") == "not-applicable" ? "N/A" : "GAP"
  end

  def status_class(check) = Report.expected_gap?(check) ? "gap" : check["status"]

  # "12 pass 1 fail 3 gap 2 skip" for a report's checks: a gap is a failure the catalogue expects on this Mac.
  # confirmed: leaving out the answers given by a bare Enter (ReportFilter).
  def result_counts(report, separator: " ", confirmed: false)
    counts = report.result_counts(confirmed:)
    parts = [ tag.span("#{counts["pass"]} pass", class: "ok"), tag.span("#{counts["fail"]} fail", class: "bad") ]
    parts << tag.span("#{counts["gap"]} gap", class: "gap", title: "Failures the feature catalogue expects on this Mac: not yet supported, or no such hardware") if counts["gap"].positive?
    parts << tag.span("#{counts["skip"]} skip", class: "dim")
    safe_join(parts, separator)
  end

  # A report's build: its id, linked to the reports on it, with the kernel, boot package and candidate set.
  def build_summary(report, long: false)
    build = report.build or return tag.span("–", class: "dim")
    parts = [ link_to(build.label, reports_path(build: build.words), class: "build-id", title: build.words) ]
    parts << link_to("set page", candidate_path(build.candidate_set)) if long && build.candidate_set && CandidateSet.names.include?(build.candidate_set)
    parts << "runtime #{build.id}" if long && build.candidate_set
    parts << tag.span(safe_join([ "set ", candidate_link(build.set) ]), title: "matched by its omarchy package") if build.matched_set
    if long
      parts << "linux-aurora #{build.kernel}" if build.kernel
      parts << "omarchy-mac-boot #{build.boot}" if build.boot
      parts << "built #{build.built}" if build.built
      parts << "tester #{report.tool_version}" if report.tool_version
    end
    tag.span(safe_join(parts, " · "), class: "build")
  end

  # A candidate set's name, linked when runs name it (CandidateSet.names, once per request).
  def candidate_link(name) = CandidateSet.names.include?(name) ? link_to(name, candidate_path(name)) : name

  # A benchmark score as it reads best: whole points, frames per second to one decimal.
  def score_words(value)
    return "–" if value.nil?

    value.to_f == value.to_i ? number_with_delimiter(value.to_i) : number_with_delimiter(value.to_f.round(1))
  end

  # "?a=1&b=2", or "" for no parameters: a filtered view's link (ReportFilter#to_params).
  def query(params) = params.empty? ? "" : "?#{params.to_query}"
end
