# frozen_string_literal: true

require 'json'
require 'sketchup'

module Move1mm
  PLUGIN_VERSION = "1.0.4"
  GITHUB_USER    = "byurii94"
  GITHUB_REPO    = "move_1mm"
  GITHUB_BRANCH  = "main"
  RAW_BASE_URL   = "https://raw.githubusercontent.com/#{GITHUB_USER}/#{GITHUB_REPO}/#{GITHUB_BRANCH}"

  @active_tool = nil
  @http_requests = []

  def self.active_tool=(tool)
    @active_tool = tool
  end

  def self.active_tool
    @active_tool
  end

  def self.version_newer?(remote_ver, local_ver)
    r_parts = remote_ver.to_s.strip.split('.').map(&:to_i)
    l_parts = local_ver.to_s.strip.split('.').map(&:to_i)
    max_len = [r_parts.length, l_parts.length].max
    max_len.times do |i|
      rv = r_parts[i] || 0
      lv = l_parts[i] || 0
      return true  if rv > lv
      return false if rv < lv
    end
    false
  end

  def self.send_http_get(url, &callback)
    req = Sketchup::Http::Request.new(url, Sketchup::Http::GET)
    @http_requests << req

    req.start do |request, response|
      @http_requests.delete(req)
      callback.call(request, response)
    end
  end

  def self.check_for_updates(silent: true)
    url = "#{RAW_BASE_URL}/version.json?t=#{Time.now.to_i}"
    puts "[Move1mm] Перевірка оновлення: #{url}" unless silent

    send_http_get(url) do |_request, response|
      code = response ? response.status_code : nil
      puts "[Move1mm] Відповідь GitHub: status=#{code}" unless silent

      if response.nil? || code != 200
        unless silent
          UI.messagebox("Не вдалося перевірити оновлення на GitHub (код: #{code || 'немає з’єднання'}).\nПеревірте, чи існує version.json у гілці '#{GITHUB_BRANCH}'.")
        end
        next
      end

      begin
        data = JSON.parse(response.body.to_s)
      rescue => e
        puts "[Move1mm] Помилка JSON: #{e.message}"
        UI.messagebox("Помилка читання version.json з GitHub: #{e.message}") unless silent
        next
      end

      remote_ver = data["version"].to_s.strip
      if remote_ver.empty? || !version_newer?(remote_ver, PLUGIN_VERSION)
        UI.messagebox("Встановлена актуальна версія 1mm Move (v#{PLUGIN_VERSION}).") unless silent
        next
      end

      notes = data["notes"].to_s.strip
      msg = "Доступна нова версія 1mm Move: v#{remote_ver} (поточна: v#{PLUGIN_VERSION})."
      msg += "\n\nЗміни:\n#{notes}" unless notes.empty?
      msg += "\n\nОновити плагін зараз?"

      if UI.messagebox(msg, MB_YESNO) == IDYES
        download_and_install_update(remote_ver)
      end
    end
  end

  def self.download_and_install_update(remote_ver)
    file_path = __FILE__
    url = "#{RAW_BASE_URL}/move_1mm.rb?t=#{Time.now.to_i}"

    send_http_get(url) do |_request, response|
      if response.nil? || response.status_code != 200 || response.body.to_s.strip.empty?
        UI.messagebox("Не вдалося завантажити move_1mm.rb з GitHub (код: #{response ? response.status_code : 'немає з’єднання'}).")
        next
      end

      begin
        File.binwrite(file_path, response.body)
        UI.messagebox("1mm Move оновлено до v#{remote_ver}! Перезапустіть SketchUp.")
      rescue => e
        UI.messagebox("Помилка запису оновлення: #{e.message}")
      end
    end
  end

  class Move1mmTool
    def initialize(entities)
      @entities = entities.select(&:valid?)
      @bounds_boxes = collect_bounds_boxes(@entities)

      @ip_start = Sketchup::InputPoint.new
      @ip_curr  = Sketchup::InputPoint.new

      @dragging    = false
      @copy_mode   = false
      @start_pt    = nil
      @snapped_vec = Geom::Vector3d.new(0, 0, 0)
      @locked_axis = nil
    end

    def activate
      Move1mm.active_tool = self
      @dragging = false
      @copy_mode = false
      @start_pt = nil
      @snapped_vec = Geom::Vector3d.new(0, 0, 0)
      @locked_axis = nil

      Sketchup.vcb_label = "Відстань (1 мм)"
      Sketchup.vcb_value = "0 мм"
      update_status
      Sketchup.active_model.active_view&.invalidate
    end

    def deactivate(view)
      Move1mm.active_tool = nil if Move1mm.active_tool == self
      @ip_start = nil
      @ip_curr  = nil
      view.invalidate if view
    end

    def onCancel(_reason, view)
      if @dragging
        @dragging = false
        @copy_mode = false
        @start_pt = nil
        @locked_axis = nil
        @snapped_vec = Geom::Vector3d.new(0, 0, 0)
        Sketchup.vcb_value = "0 мм"
        update_status
        view.invalidate
      else
        Sketchup.active_model.select_tool(nil)
      end
    end

    def onKeyDown(key, repeat, _flags, view)
      case key
      when 27 # ESC
        onCancel(0, view)
      when VK_CONTROL
        return if repeat > 1
        @copy_mode = !@copy_mode
        update_status
        view.invalidate
      when VK_RIGHT
        toggle_axis_lock(:x, view)
      when VK_LEFT
        toggle_axis_lock(:y, view)
      when VK_UP
        toggle_axis_lock(:z, view)
      when VK_DOWN
        @locked_axis = nil
        update_snapped_vec(view) if @dragging
        update_status
        view.invalidate
      end
    end

    def onMouseMove(_flags, x, y, view)
      if !@dragging
        prev_pt = @ip_start.valid? ? @ip_start.position.clone : nil
        prev_tip = @ip_start.valid? ? @ip_start.tooltip.to_s : ""
        @ip_start.pick(view, x, y)
        new_pt = @ip_start.valid? ? @ip_start.position : nil
        new_tip = @ip_start.valid? ? @ip_start.tooltip.to_s : ""

        if prev_pt != new_pt || prev_tip != new_tip
          view.tooltip = new_tip
          update_status
          view.invalidate
        end
        return
      end

      prev_vec = @snapped_vec.clone
      prev_snap_pt = @ip_curr.valid? ? @ip_curr.position.clone : nil
      prev_tip = @ip_curr.valid? ? @ip_curr.tooltip.to_s : ""

      @ip_curr.pick(view, x, y, @ip_start)
      update_snapped_vec(view)

      new_snap_pt = @ip_curr.valid? ? @ip_curr.position : nil
      new_tip = @ip_curr.valid? ? @ip_curr.tooltip.to_s : ""

      if @snapped_vec != prev_vec || new_snap_pt != prev_snap_pt || new_tip != prev_tip
        view.tooltip = new_tip
        Sketchup.vcb_value = "#{@snapped_vec.length.to_mm.round} мм"
        update_status
        view.invalidate
      end
    end

    def onLButtonDown(_flags, x, y, view)
      if !@dragging
        @ip_start.pick(view, x, y)
        return unless @ip_start.valid?

        @start_pt = Geom::Point3d.new(@ip_start.position)
        @snapped_vec = Geom::Vector3d.new(0, 0, 0)
        @dragging = true
        update_status
        view.invalidate
      else
        commit_move(@snapped_vec, view)
      end
    end

    def onUserText(text, view)
      return unless @dragging && @start_pt

      dist_mm = text.to_s.tr(',', '.').to_f.round
      dir = current_direction
      return if dir.length < 1e-6

      target_vec = Geom::Vector3d.new(
        dir.x * dist_mm.mm,
        dir.y * dist_mm.mm,
        dir.z * dist_mm.mm
      )
      commit_move(target_vec, view)
    end

    def draw(view)
      if !@dragging
        @ip_start.draw(view) if @ip_start&.valid?
        return
      end

      return unless @start_pt

      @ip_curr.draw(view) if @ip_curr&.valid?

      end_pt = @start_pt + @snapped_vec
      col = axis_color(@snapped_vec)

      tr = Geom::Transformation.translation(@snapped_vec)
      view.drawing_color = col
      view.line_width = (@copy_mode ? 2 : 1)
      @bounds_boxes.each do |corners|
        moved = corners.map { |pt| pt.transform(tr) }
        draw_box_edges(view, moved)
      end

      if @ip_curr&.valid?
        raw_pt = @ip_curr.position
        if raw_pt.distance(end_pt) > 0.1.mm
          view.drawing_color = Sketchup::Color.new(156, 163, 175)
          view.line_width = 1
          view.draw(GL_LINES, [raw_pt, end_pt])
        end
      end

      view.drawing_color = col
      view.line_width = (@locked_axis ? 3 : 2)
      view.draw(GL_LINES, [@start_pt, end_pt])
      view.draw_points([@start_pt, end_pt], 8, 2, Sketchup::Color.new(30, 30, 30))
    end

    private

    def collect_bounds_boxes(entities)
      entities.filter_map do |ent|
        next unless ent && ent.valid? && ent.respond_to?(:bounds)
        b = ent.bounds
        next if b.empty?
        (0..7).map { |i| b.corner(i) }
      end
    end

    def draw_box_edges(view, c)
      segs = [
        c[0], c[1], c[1], c[3], c[3], c[2], c[2], c[0],
        c[4], c[5], c[5], c[7], c[7], c[6], c[6], c[4],
        c[0], c[4], c[1], c[5], c[2], c[6], c[3], c[7]
      ]
      view.draw(GL_LINES, segs)
    end

    def toggle_axis_lock(axis, view)
      @locked_axis = (@locked_axis == axis) ? nil : axis
      update_snapped_vec(view) if @dragging
      Sketchup.vcb_value = "#{@snapped_vec.length.to_mm.round} мм" if @dragging
      update_status
      view.invalidate
    end

    def axis_vector(axis)
      case axis
      when :x then Geom::Vector3d.new(1, 0, 0)
      when :y then Geom::Vector3d.new(0, 1, 0)
      when :z then Geom::Vector3d.new(0, 0, 1)
      else nil
      end
    end

    def axis_color(vec)
      ax = @locked_axis || detect_major_axis(vec)
      case ax
      when :x then Sketchup::Color.new(220, 38, 38)
      when :y then Sketchup::Color.new(22, 163, 74)
      when :z then Sketchup::Color.new(37, 99, 235)
      else Sketchup::Color.new(107, 114, 128)
      end
    end

    def detect_major_axis(vec)
      return nil if vec.length < 1e-6
      u = vec.normalize
      return :x if u.x.abs > 0.999
      return :y if u.y.abs > 0.999
      return :z if u.z.abs > 0.999
      nil
    end

    def current_direction
      if @locked_axis
        v = axis_vector(@locked_axis)
        raw = @ip_curr&.valid? ? (@ip_curr.position - @start_pt) : @snapped_vec
        sign = (raw % v) < 0 ? -1.0 : 1.0
        return Geom::Vector3d.new(v.x * sign, v.y * sign, v.z * sign)
      end

      return @snapped_vec.normalize if @snapped_vec.length > 1e-6
      if @ip_curr&.valid?
        raw = @ip_curr.position - @start_pt
        return raw.normalize if raw.length > 1e-6
      end
      Geom::Vector3d.new(1, 0, 0)
    end

    def update_snapped_vec(_view)
      return unless @start_pt && @ip_curr&.valid?

      raw_vec = @ip_curr.position - @start_pt

      if @locked_axis
        ax = axis_vector(@locked_axis)
        proj_mm = (raw_vec % ax).to_mm.round
        @snapped_vec = Geom::Vector3d.new(
          ax.x * proj_mm.mm,
          ax.y * proj_mm.mm,
          ax.z * proj_mm.mm
        )
        return
      end

      len_mm = raw_vec.length.to_mm
      if len_mm <= 0.1
        @snapped_vec = Geom::Vector3d.new(0, 0, 0)
        return
      end

      u = raw_vec.normalize
      if u.x.abs > 0.985 && u.y.abs < 0.12 && u.z.abs < 0.12
        @snapped_vec = Geom::Vector3d.new(raw_vec.x.to_mm.round.mm, 0, 0)
      elsif u.y.abs > 0.985 && u.x.abs < 0.12 && u.z.abs < 0.12
        @snapped_vec = Geom::Vector3d.new(0, raw_vec.y.to_mm.round.mm, 0)
      elsif u.z.abs > 0.985 && u.x.abs < 0.12 && u.y.abs < 0.12
        @snapped_vec = Geom::Vector3d.new(0, 0, raw_vec.z.to_mm.round.mm)
      else
        @snapped_vec = Geom::Vector3d.new(
          raw_vec.x.to_mm.round.mm,
          raw_vec.y.to_mm.round.mm,
          raw_vec.z.to_mm.round.mm
        )
      end
    end

    def commit_move(vec, view)
      if vec && vec.length > 1e-9
        model = Sketchup.active_model
        op_name = @copy_mode ? "Копіювання з кроком 1 мм" : "Переміщення з кроком 1 мм"
        model.start_operation(op_name, true)
        tr = Geom::Transformation.translation(vec)

        if @copy_mode
          new_entities = []
          @entities.each do |ent|
            next unless ent && ent.valid?
            copied = copy_entity_with_transform(ent, tr)
            new_entities << copied if copied && copied.valid?
          end
          unless new_entities.empty?
            model.selection.clear
            model.selection.add(new_entities)
            @entities = new_entities
          end
        else
          @entities.each do |ent|
            ent.transform!(tr) if ent && ent.valid?
          end
        end

        model.commit_operation
        @bounds_boxes = collect_bounds_boxes(@entities)
      end

      @dragging = false
      @copy_mode = false
      @start_pt = nil
      @snapped_vec = Geom::Vector3d.new(0, 0, 0)
      Sketchup.vcb_value = "#{vec ? vec.length.to_mm.round : 0} мм"
      update_status
      view.invalidate
    end

    def copy_entity_with_transform(ent, tr)
      if ent.is_a?(Sketchup::Group)
        cp = ent.copy
        cp.transform!(tr)
        cp.material = ent.material if ent.material
        cp.layer = ent.layer if ent.layer
        cp.name = ent.name if ent.name && !ent.name.empty?
        cp
      elsif ent.is_a?(Sketchup::ComponentInstance)
        inst = ent.parent.entities.add_instance(ent.definition, ent.transformation * tr)
        inst.material = ent.material if ent.material
        inst.layer = ent.layer if ent.layer
        inst.name = ent.name if ent.name && !ent.name.empty?
        inst
      else
        nil
      end
    end

    def snap_info_text
      ip = @dragging ? @ip_curr : @ip_start
      return "" unless ip && ip.valid?
      tip = ip.tooltip.to_s.strip
      tip.empty? ? "" : " | Прив'язка: #{tip}"
    end

    def update_status
      mode_txt = @copy_mode ? " [КОПІЯ]" : ""
      lock_txt = case @locked_axis
                 when :x then " [Вісь X]"
                 when :y then " [Вісь Y]"
                 when :z then " [Вісь Z]"
                 else ""
                 end

      if !@dragging
        Sketchup.set_status_text("📏 1mm Move#{mode_txt}#{lock_txt}: клікніть базову точку#{snap_info_text} | Ctrl = копія | Шорткат або ESC = вихід")
      else
        d = @snapped_vec.length.to_mm.round
        Sketchup.set_status_text("📏 1mm Move#{mode_txt}#{lock_txt}: зсув #{d} мм#{snap_info_text} | Стрілки = вісь | Клік або число+Enter = фіксація | ESC = скасувати")
      end
    end
  end

  def self.run
    model = Sketchup.active_model
    return unless model

    current_tool = model.tools.active_tool
    if current_tool.is_a?(Move1mmTool)
      model.select_tool(nil)
      return
    end

    if model.selection.empty?
      UI.messagebox("Спочатку виділіть об'єкт або групу для переміщення.")
      return
    end

    model.select_tool(Move1mmTool.new(model.selection.to_a))
  end

  unless file_loaded?(__FILE__)
    ext_menu = UI.menu("Extensions")
    ext_menu.add_item("Переміщення з кроком 1 мм (1mm Move)") { run }
    ext_menu.add_item("Перевірити оновлення (1mm Move)") { check_for_updates(silent: false) }

    UI.start_timer(30.0, false) { check_for_updates(silent: true) }
    file_loaded(__FILE__)
  end
end
