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

      @ip_curr.draw(view) if @ip_curr
