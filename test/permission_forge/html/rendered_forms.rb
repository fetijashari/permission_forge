require 'nokogiri'

module PermissionForge
  module Html
    # Submitting an admin form exactly as the page renders it: GET the page,
    # take the successful controls of the form posting to an action (as a
    # browser sends them), override some, post. Included by the tests that
    # submit forms unchanged (generated_text_unchanged_submit_test.rb,
    # unchanged_save_flash_test.rb).
    module RenderedForms
      FORM_TYPE = 'application/x-www-form-urlencoded'.freeze

      private

      # The successful controls of `form` as a browser sends them: inputs
      # inside it or naming it (`form="id"`), checked boxes only, the
      # selected option, no buttons, nothing disabled.
      def form_pairs(doc, form)
        controls = form.css('input, select, textarea').to_a
        controls += doc.css(%([form="#{form['id']}"])).to_a if form['id']
        controls.uniq.filter_map { |control| control_pair(control) }
      end

      def control_pair(control)
        name = control['name']
        return if name.nil? || control.key?('disabled')

        case control.name
        when 'select' then [name, selected_value(control)]
        when 'textarea' then [name, control.text]
        else input_pair(control, name)
        end
      end

      def input_pair(control, name)
        type = control['type'].to_s.downcase
        return if %w[submit button image reset file].include?(type)
        return if %w[checkbox radio].include?(type) && !control.key?('checked')

        [name, control['value'].to_s]
      end

      def selected_value(select)
        option = select.at_css('option[selected]') || select.at_css('option')
        option ? (option['value'] || option.text).to_s : ''
      end

      # GETs `page`, then submits the form whose action is `action`, as
      # rendered, with `overrides` — to `to` when given (the set page's
      # "review" form, sent straight to "apply").
      def submit_as_rendered(page, action, to: nil, **overrides)
        form, pairs = rendered_form(page, action)
        pairs = pairs.reject { |name, _| overrides.key?(name) } + overrides.to_a
        post to ? pf(to) : form['action'], params: URI.encode_www_form(pairs), headers: { 'CONTENT_TYPE' => FORM_TYPE }
        assert_response :redirect
      end

      # [form, its pairs as rendered] of the form on `page` posting to `action`.
      def rendered_form(page, action)
        get pf(page)
        assert_response :success
        doc = Nokogiri::HTML(response.body)
        form = doc.css('form').find { |node| node['action'] == pf(action) }
        assert form, "no form posting to #{action} on #{page}"
        [form, form_pairs(doc, form)]
      end
    end
  end
end
