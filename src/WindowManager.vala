//
//  Copyright (C) 2012-2014 Tom Beckmann, Rico Tzschichholz
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

namespace Gala {
    const string DAEMON_DBUS_NAME = "org.pantheon.gala.daemon";
    const string DAEMON_DBUS_OBJECT_PATH = "/org/pantheon/gala/daemon";

    [DBus (name = "org.pantheon.gala.daemon")]
    public interface Daemon: GLib.Object {
        public abstract async void show_window_menu (WindowFlags flags, int x, int y) throws Error;
        public abstract async void show_desktop_menu (int x, int y) throws Error;
    }

    public class WindowManagerGala : Meta.Plugin, WindowManager {
        /**
         * {@inheritDoc}
         */
        public Clutter.Actor ui_group { get; protected set; }

        /**
         * {@inheritDoc}
         */
        public Clutter.Stage stage { get; protected set; }

        /**
         * {@inheritDoc}
         */
        public Clutter.Actor window_group { get; protected set; }

        /**
         * {@inheritDoc}
         */
        public Clutter.Actor top_window_group { get; protected set; }

        /**
         * {@inheritDoc}
         */
        public Meta.BackgroundGroup background_group { get; protected set; }

        /**
         * {@inheritDoc}
         */
         public Gala.ActivatableComponent workspace_view { get; protected set; }

        /**
         * {@inheritDoc}
         */
        public bool enable_animations { get; protected set; }

        public ScreenShield? screen_shield { get; private set; }

        public PointerLocator pointer_locator { get; private set; }

        SystemBackground system_background;

        Meta.PluginInfo info;

        WindowSwitcher? winswitcher = null;
        ActivatableComponent? window_overview = null;

        public ScreenSaverManager? screensaver { get; private set; }

        HotCornerManager? hot_corner_manager = null;

        /**
         * Allow to zoom in/out the entire desktop.
         */
        Zoom? zoom = null;

        AccentColorManager accent_color_manager;

        Clutter.Actor? tile_preview;

        private Meta.Window? moving; //place for the window that is being moved over

        Daemon? daemon_proxy = null;

        NotificationStack notification_stack;

        Gee.LinkedList<ModalProxy> modal_stack = new Gee.LinkedList<ModalProxy> ();

        Gee.HashSet<Meta.WindowActor> minimizing = new Gee.HashSet<Meta.WindowActor> ();
        Gee.HashSet<Meta.WindowActor> maximizing = new Gee.HashSet<Meta.WindowActor> ();
        Gee.HashSet<Meta.WindowActor> unmaximizing = new Gee.HashSet<Meta.WindowActor> ();
        Gee.HashSet<Meta.WindowActor> mapping = new Gee.HashSet<Meta.WindowActor> ();
        Gee.HashSet<Meta.WindowActor> destroying = new Gee.HashSet<Meta.WindowActor> ();
        Gee.HashSet<Meta.WindowActor> unminimizing = new Gee.HashSet<Meta.WindowActor> ();
        GLib.HashTable<Meta.Window, int> ws_assoc = new GLib.HashTable<Meta.Window, int> (direct_hash, direct_equal);
        Meta.SizeChange? which_change = null;
        Meta.Rectangle old_rect_size_change;

        private GLib.Settings animations_settings;
        private GLib.Settings behavior_settings;

        private GestureTracker gesture_tracker;
        private bool animating_switch_workspace = false;
        private bool switch_workspace_with_gesture = false;

        /**
         * Amount of pixels to move on the nudge animation.
         */
        public const float NUDGE_GAP = 32;

        /**
         * Gap to show between workspaces while switching between them.
         */
        public const int WORKSPACE_GAP = 24;

        construct {
            gesture_tracker = new GestureTracker (AnimationDuration.WORKSPACE_SWITCH_MIN, AnimationDuration.WORKSPACE_SWITCH);
            gesture_tracker.enable_touchpad ();
            gesture_tracker.on_gesture_detected.connect (on_gesture_detected);

            info = Meta.PluginInfo () {name = "Gala", version = Config.VERSION, author = "Gala Developers",
                license = "GPLv3", description = "A nice elementary window manager"};

            animations_settings = new GLib.Settings (Config.SCHEMA + ".animations");
            animations_settings.bind ("enable-animations", this, "enable-animations", GLib.SettingsBindFlags.GET);
            behavior_settings = new GLib.Settings (Config.SCHEMA + ".behavior");
            enable_animations = animations_settings.get_boolean ("enable-animations");
        }

        public override void start () {
            show_stage ();

            Bus.watch_name (BusType.SESSION, DAEMON_DBUS_NAME, BusNameWatcherFlags.NONE, daemon_appeared, lost_daemon);
            AccessDialog.watch_portal ();

            unowned Meta.Display display = get_display ();
            display.gl_video_memory_purged.connect (() => {
                Meta.Background.refresh_all ();
                SystemBackground.refresh ();
            });
        }

        void lost_daemon () {
            daemon_proxy = null;
        }

        void daemon_appeared () {
            if (daemon_proxy == null) {
                Bus.get_proxy.begin<Daemon> (BusType.SESSION, DAEMON_DBUS_NAME, DAEMON_DBUS_OBJECT_PATH, 0, null, (obj, res) => {
                    try {
                        daemon_proxy = Bus.get_proxy.end (res);
                    } catch (Error e) {
                        warning ("Failed to get Menu proxy: %s", e.message);
                    }
                });
            }
        }

        bool show_stage () {
            unowned Meta.Display display = get_display ();

            screen_shield = new ScreenShield (this);
            screensaver = new ScreenSaverManager (screen_shield);

            DBus.init (this);
            DBusAccelerator.init (this);
            MediaFeedback.init ();

            WindowListener.init (display);
            KeyboardManager.init (display);

            notification_stack = new NotificationStack (display);

            // Due to a bug which enables access to the stage when using multiple monitors
            // in the screensaver, we have to listen for changes and make sure the input area
            // is set to NONE when we are in locked mode
            screensaver.active_changed.connect (update_input_area);

            stage = display.get_stage () as Clutter.Stage;
            var background_settings = new GLib.Settings ("org.gnome.desktop.background");
            var color = background_settings.get_string ("primary-color");
            stage.background_color = Clutter.Color.from_string (color);

            Meta.Util.later_add (Meta.LaterType.BEFORE_REDRAW, () => {
                WorkspaceManager.init (this);
                return false;
            });

            /* our layer structure, copied from gnome-shell (from bottom to top):
             * stage
             * + system background
             * + ui group
             * +-- window group
             * +---- background manager
             * +-- shell elements
             * +-- top window group
             */

            system_background = new SystemBackground (display);

            system_background.background_actor.add_constraint (new Clutter.BindConstraint (stage,
                Clutter.BindCoordinate.ALL, 0));
            stage.insert_child_below (system_background.background_actor, null);

            ui_group = new Clutter.Actor ();
            ui_group.reactive = true;
            stage.add_child (ui_group);

            window_group = display.get_window_group ();
            stage.remove_child (window_group);
            ui_group.add_child (window_group);

            background_group = new BackgroundContainer (display);
            ((BackgroundContainer)background_group).show_background_menu.connect (on_show_background_menu);
            window_group.add_child (background_group);
            window_group.set_child_below_sibling (background_group, null);

            top_window_group = display.get_top_window_group ();

            pointer_locator = new PointerLocator (this);
            ui_group.add_child (pointer_locator);
            ui_group.add_child (new DwellClickTimer (this));

            ui_group.add_child (screen_shield);

            stage.remove_child (top_window_group);
            ui_group.add_child (top_window_group);

            /*keybindings*/
            var keybinding_settings = new GLib.Settings (Config.SCHEMA + ".keybindings");

            display.add_keybinding ("switch-to-workspace-first", keybinding_settings, 0, (Meta.KeyHandlerFunc) handle_switch_to_workspace_end);
            display.add_keybinding ("switch-to-workspace-last", keybinding_settings, 0, (Meta.KeyHandlerFunc) handle_switch_to_workspace_end);
            display.add_keybinding ("move-to-workspace-first", keybinding_settings, 0, (Meta.KeyHandlerFunc) handle_move_to_workspace_end);
            display.add_keybinding ("move-to-workspace-last", keybinding_settings, 0, (Meta.KeyHandlerFunc) handle_move_to_workspace_end);
            display.add_keybinding ("cycle-workspaces-next", keybinding_settings, 0, (Meta.KeyHandlerFunc) handle_cycle_workspaces);
            display.add_keybinding ("cycle-workspaces-previous", keybinding_settings, 0, (Meta.KeyHandlerFunc) handle_cycle_workspaces);

            display.overlay_key.connect (() => {
                launch_action ("overlay-action");
            });

            Meta.KeyBinding.set_custom_handler ("panel-main-menu", () => {
                launch_action ("panel-main-menu-action");
            });

            Meta.KeyBinding.set_custom_handler ("toggle-recording", () => {
                launch_action ("toggle-recording-action");
            });

            Meta.KeyBinding.set_custom_handler ("switch-to-workspace-up", () => {});
            Meta.KeyBinding.set_custom_handler ("switch-to-workspace-down", () => {});
            Meta.KeyBinding.set_custom_handler ("switch-to-workspace-left", (Meta.KeyHandlerFunc) handle_switch_to_workspace);
            Meta.KeyBinding.set_custom_handler ("switch-to-workspace-right", (Meta.KeyHandlerFunc) handle_switch_to_workspace);

            Meta.KeyBinding.set_custom_handler ("move-to-workspace-up", () => {});
            Meta.KeyBinding.set_custom_handler ("move-to-workspace-down", () => {});
            Meta.KeyBinding.set_custom_handler ("move-to-workspace-left", (Meta.KeyHandlerFunc) handle_move_to_workspace);
            Meta.KeyBinding.set_custom_handler ("move-to-workspace-right", (Meta.KeyHandlerFunc) handle_move_to_workspace);

            Meta.KeyBinding.set_custom_handler ("switch-group", () => {});
            Meta.KeyBinding.set_custom_handler ("switch-group-backward", () => {});

            /*shadows*/
            InternalUtils.reload_shadow ();
            var shadow_settings = new GLib.Settings (Config.SCHEMA + ".shadows");
            shadow_settings.changed.connect (InternalUtils.reload_shadow);

            Meta.MonitorManager.@get ().monitors_changed.connect (on_monitors_changed);

            hot_corner_manager = new HotCornerManager (this, behavior_settings);
            hot_corner_manager.on_configured.connect (update_input_area);
            hot_corner_manager.configure ();

            zoom = new Zoom (this);

            accent_color_manager = new AccentColorManager ();

            // initialize plugins and add default components if no plugin overrides them
            var plugin_manager = PluginManager.get_default ();
            plugin_manager.initialize (this);
            plugin_manager.regions_changed.connect (update_input_area);

            if (plugin_manager.workspace_view_provider == null
                || (workspace_view = (plugin_manager.get_plugin (plugin_manager.workspace_view_provider) as ActivatableComponent)) == null) {
                workspace_view = new MultitaskingView (this);
                ui_group.add_child ((Clutter.Actor) workspace_view);
            }

            Meta.KeyBinding.set_custom_handler ("show-desktop", () => {
                if (workspace_view.is_opened ())
                    workspace_view.close ();
                else
                    workspace_view.open ();
            });

            if (plugin_manager.window_switcher_provider == null) {
                winswitcher = new WindowSwitcher (this);
                ui_group.add_child (winswitcher);

                Meta.KeyBinding.set_custom_handler ("switch-applications", (Meta.KeyHandlerFunc) winswitcher.handle_switch_windows);
                Meta.KeyBinding.set_custom_handler ("switch-applications-backward", (Meta.KeyHandlerFunc) winswitcher.handle_switch_windows);
                Meta.KeyBinding.set_custom_handler ("switch-windows", (Meta.KeyHandlerFunc) winswitcher.handle_switch_windows);
                Meta.KeyBinding.set_custom_handler ("switch-windows-backward", (Meta.KeyHandlerFunc) winswitcher.handle_switch_windows);
            }

            if (plugin_manager.window_overview_provider == null
                || (window_overview = (plugin_manager.get_plugin (plugin_manager.window_overview_provider) as ActivatableComponent)) == null) {
                window_overview = new WindowOverview (this);
                ui_group.add_child ((Clutter.Actor) window_overview);
            }

            display.add_keybinding ("expose-windows", keybinding_settings, 0, () => {
                if (window_overview.is_opened ())
                    window_overview.close ();
                else
                    window_overview.open ();
            });
            display.add_keybinding ("expose-all-windows", keybinding_settings, 0, () => {
                if (window_overview.is_opened ())
                    window_overview.close ();
                else {
                    var hints = new HashTable<string,Variant> (str_hash, str_equal);
                    hints.@set ("all-windows", true);
                    window_overview.open (hints);
                }
            });

            update_input_area ();

            stage.show ();

            Idle.add (() => {
                // let the session manager move to the next phase
#if WITH_SYSTEMD
                Systemd.Daemon.notify (true, "READY=1");
#endif
#if HAS_MUTTER41
                display.get_context ().notify_ready ();
#else
                Meta.register_with_session ();
#endif
                plugin_manager.load_waiting_plugins ();
                return GLib.Source.REMOVE;
            });

            return false;
        }

        private void launch_action (string action_key) {
            try {
                var action = behavior_settings.get_string (action_key);
                if (action != null && action != "") {
                    Process.spawn_command_line_async (action);
                }
            } catch (Error e) { warning (e.message); }
        }

        void on_show_background_menu (int x, int y) {
            if (daemon_proxy == null) {
                return;
            }

                daemon_proxy.show_desktop_menu.begin (x, y, (obj, res) => {
                    try {
                        ((Daemon) obj).show_desktop_menu.end (res);
                    } catch (Error e) {
                        message ("Error invoking MenuManager: %s", e.message);
                    }
                });
        }

        void on_monitors_changed () {
            screen_shield.expand_to_screen_size ();
        }

        [CCode (instance_pos = -1)]
        void handle_cycle_workspaces (Meta.Display display, Meta.Window? window, Clutter.KeyEvent event,
            Meta.KeyBinding binding) {
            var direction = (binding.get_name () == "cycle-workspaces-next" ? 1 : -1);
            unowned Meta.WorkspaceManager manager = display.get_workspace_manager ();
            var index = manager.get_active_workspace_index () + direction;

            int dynamic_offset = Meta.Prefs.get_dynamic_workspaces () ? 1 : 0;

            if (index < 0)
                index = manager.get_n_workspaces () - 1 - dynamic_offset;
            else if (index > manager.get_n_workspaces () - 1 - dynamic_offset)
                index = 0;

            manager.get_workspace_by_index (index).activate (display.get_current_time ());
        }

        [CCode (instance_pos = -1)]
        void handle_move_to_workspace (Meta.Display display, Meta.Window? window,
            Clutter.KeyEvent event, Meta.KeyBinding binding) {
            if (window == null)
                return;

            var direction = (binding.get_name () == "move-to-workspace-left" ? Meta.MotionDirection.LEFT : Meta.MotionDirection.RIGHT);
            move_window (window, direction);
        }

        [CCode (instance_pos = -1)]
        void handle_move_to_workspace_end (Meta.Display display, Meta.Window? window,
            Clutter.KeyEvent event, Meta.KeyBinding binding) {
            if (window == null)
                return;

            unowned Meta.WorkspaceManager manager = display.get_workspace_manager ();
            var index = (binding.get_name () == "move-to-workspace-first" ? 0 : manager.get_n_workspaces () - 1);
            var workspace = manager.get_workspace_by_index (index);
            window.change_workspace (workspace);
            workspace.activate_with_focus (window, display.get_current_time ());
        }

        [CCode (instance_pos = -1)]
        void handle_switch_to_workspace (Meta.Display display, Meta.Window? window,
            Clutter.KeyEvent event, Meta.KeyBinding binding) {
            var direction = (binding.get_name () == "switch-to-workspace-left" ? Meta.MotionDirection.LEFT : Meta.MotionDirection.RIGHT);
            switch_to_next_workspace (direction);
        }

        [CCode (instance_pos = -1)]
        void handle_switch_to_workspace_end (Meta.Display display, Meta.Window? window,
            Clutter.KeyEvent event, Meta.KeyBinding binding) {
            unowned Meta.WorkspaceManager manager = display.get_workspace_manager ();
            var index = (binding.get_name () == "switch-to-workspace-first" ? 0 : manager.n_workspaces - 1);
            manager.get_workspace_by_index (index).activate (display.get_current_time ());
        }

        private void on_gesture_detected (Gesture gesture) {
            if (workspace_view.is_opened ()) {
                return;
            }

            var can_handle_swipe = gesture.type == Gdk.EventType.TOUCHPAD_SWIPE &&
                (gesture.direction == GestureDirection.LEFT || gesture.direction == GestureDirection.RIGHT);

            var fingers = (gesture.fingers == 3 && GestureSettings.get_string ("three-finger-swipe-horizontal") == "switch-to-workspace") ||
                (gesture.fingers == 4 && GestureSettings.get_string ("four-finger-swipe-horizontal") == "switch-to-workspace");

            switch_workspace_with_gesture = can_handle_swipe && fingers;
            if (switch_workspace_with_gesture) {
                var direction = gesture_tracker.settings.get_natural_scroll_direction (gesture);
                switch_to_next_workspace (direction);
            }
        }

        /**
         * {@inheritDoc}
         */
        public void switch_to_next_workspace (Meta.MotionDirection direction) {
            if (animating_switch_workspace) {
                return;
            }

            unowned Meta.Display display = get_display ();
            var active_workspace = display.get_workspace_manager ().get_active_workspace ();
            var neighbor = active_workspace.get_neighbor (direction);

            if (neighbor != active_workspace) {
                neighbor.activate (display.get_current_time ());
            } else {
                // if we didn't switch, show a nudge-over animation if one is not already in progress
                if (workspace_view.is_opened () && workspace_view is MultitaskingView) {
                    ((MultitaskingView) workspace_view).play_nudge_animation (direction);
                } else {
                    play_nudge_animation (direction);
                }
            }
        }

        private void play_nudge_animation (Meta.MotionDirection direction) {
            if (!enable_animations) {
                return;
            }

            animating_switch_workspace = true;
            var nudge_gap = NUDGE_GAP * InternalUtils.get_ui_scaling_factor ();

            float dest = 0;
            if (!switch_workspace_with_gesture) {
                dest = nudge_gap;
            } else {
                unowned Meta.Display display = get_display ();
                var workspaces_geometry = InternalUtils.get_workspaces_geometry (display);
                dest = workspaces_geometry.width;
            }

            if (direction == Meta.MotionDirection.RIGHT) {
                dest *= -1;
            }

            GestureTracker.OnUpdate on_animation_update = (percentage) => {
                var x = GestureTracker.animation_value (0.0f, dest, percentage, true);
                ui_group.x = x.clamp (-nudge_gap, nudge_gap);
            };

            GestureTracker.OnEnd on_animation_end = (percentage, cancel_action) => {
                var nudge_gesture = new Clutter.PropertyTransition ("x") {
                    duration = (AnimationDuration.NUDGE / 2),
                    remove_on_complete = true,
                    progress_mode = Clutter.AnimationMode.LINEAR
                };
                nudge_gesture.set_from_value ((float) ui_group.x);
                nudge_gesture.set_to_value (0.0f);
                ui_group.add_transition ("nudge", nudge_gesture);

                switch_workspace_with_gesture = false;
                animating_switch_workspace = false;
            };

            if (!switch_workspace_with_gesture) {
                double[] keyframes = { 0.5 };
                GLib.Value[] x = { dest };

                var nudge = new Clutter.KeyframeTransition ("translation-x") {
                    duration = AnimationDuration.NUDGE,
                    remove_on_complete = true,
                    progress_mode = Clutter.AnimationMode.EASE_IN_QUAD
                };
                nudge.set_from_value (0.0f);
                nudge.set_to_value (0.0f);
                nudge.set_key_frames (keyframes);
                nudge.set_values (x);
                nudge.completed.connect (() => {
                    animating_switch_workspace = false;
                });

                ui_group.add_transition ("nudge", nudge);
            } else {
                gesture_tracker.connect_handlers (null, (owned) on_animation_update, (owned) on_animation_end);
            }
        }

        void update_input_area () {
            unowned Meta.Display display = get_display ();

            if (screensaver != null) {
                try {
                    if (screensaver.get_active ()) {
                        InternalUtils.set_input_area (display, InputArea.NONE);
                        return;
                    }
                } catch (Error e) {
                    // the screensaver object apparently won't be null even though
                    // it is unavailable. This error will be thrown however, so we
                    // can just ignore it, because if it is thrown, the screensaver
                    // is unavailable.
                }
            }

            if (is_modal ())
                InternalUtils.set_input_area (display, InputArea.FULLSCREEN);
            else
                InternalUtils.set_input_area (display, InputArea.DEFAULT);
        }

        void show_bottom_stack_window (Meta.Window bottom_window) {
            unowned Meta.Workspace workspace = bottom_window.get_workspace ();
            if (Utils.get_n_windows (workspace) == 0) {
                return;
            }

            var bottom_actor = bottom_window.get_compositor_private () as Meta.WindowActor;
            if (enable_animations) {
                animate_bottom_window_scale (bottom_actor);
            }

            uint fade_out_duration = 900U;
            double[] op_keyframes = { 0.1, 0.9 };
            GLib.Value[] opacity = { 20U, 20U };

            workspace.list_windows ().@foreach ((window) => {
                if (window.get_xwindow () == bottom_window.get_xwindow ()
                    || !InternalUtils.get_window_is_normal (window)
                    || window.minimized) {
                    return;
                }

                var actor = window.get_compositor_private () as Clutter.Actor;
                if (enable_animations) {
                    var op_trans = new Clutter.KeyframeTransition ("opacity") {
                        duration = fade_out_duration,
                        remove_on_complete = true,
                        progress_mode = Clutter.AnimationMode.EASE_IN_OUT_QUAD
                    };
                    op_trans.set_from_value (255.0f);
                    op_trans.set_to_value (255.0f);
                    op_trans.set_key_frames (op_keyframes);
                    op_trans.set_values (opacity);

                    actor.add_transition ("opacity-hide", op_trans);
                } else {
                    Timeout.add ((uint)(fade_out_duration * op_keyframes[0]), () => {
                        actor.opacity = (uint)opacity[0];
                        return false;
                    });

                    Timeout.add ((uint)(fade_out_duration * op_keyframes[1]), () => {
                        actor.opacity = 255U;
                        return false;
                    });
                }
            });
        }

        void animate_bottom_window_scale (Meta.WindowActor actor) {
            const string[] PROPS = { "scale-x", "scale-y" };

            foreach (string prop in PROPS) {
                double[] scale_keyframes = { 0.2, 0.3, 0.8 };
                GLib.Value[] scale = { 1.0f, 1.07f, 1.07f };

                var scale_trans = new Clutter.KeyframeTransition (prop) {
                    duration = 500,
                    remove_on_complete = true,
                    progress_mode = Clutter.AnimationMode.EASE_IN_QUAD
                };
                scale_trans.set_from_value (1.0f);
                scale_trans.set_to_value (1.0f);
                scale_trans.set_key_frames (scale_keyframes);
                scale_trans.set_values (scale);

                actor.add_transition ("magnify-%s".printf (prop), scale_trans);
            }
        }

        /**
         * {@inheritDoc}
         */
        public void move_window (Meta.Window? window, Meta.MotionDirection direction) {
            if (window == null)
                return;

            unowned Meta.Display display = get_display ();
            unowned Meta.WorkspaceManager manager = display.get_workspace_manager ();

            var active = manager.get_active_workspace ();
            var next = active.get_neighbor (direction);

            //dont allow empty workspaces to be created by moving, if we have dynamic workspaces
            if (Meta.Prefs.get_dynamic_workspaces () && Utils.get_n_windows (active) == 1 && next.index () == manager.n_workspaces - 1) {
                Utils.bell (display);
                return;
            }

            moving = window;

            if (!window.is_on_all_workspaces ())
                window.change_workspace (next);

            next.activate_with_focus (window, display.get_current_time ());
        }

        /**
         * {@inheritDoc}
         */
        public ModalProxy push_modal () {
            var proxy = new ModalProxy ();

            modal_stack.offer_head (proxy);

            // modal already active
            if (modal_stack.size >= 2)
                return proxy;

            unowned Meta.Display display = get_display ();
            var time = display.get_current_time ();

            update_input_area ();
#if !HAS_MUTTER42
            begin_modal (0, time);
#endif

            display.disable_unredirect ();

            return proxy;
        }

        /**
         * {@inheritDoc}
         */
        public void pop_modal (ModalProxy proxy) {
            if (!modal_stack.remove (proxy)) {
                warning ("Attempted to remove a modal proxy that was not in the stack");
                return;
            }

            if (is_modal ())
                return;

            update_input_area ();

            unowned Meta.Display display = get_display ();
#if !HAS_MUTTER42
            end_modal (display.get_current_time ());
#endif

            display.enable_unredirect ();
        }

        /**
         * {@inheritDoc}
         */
        public bool is_modal () {
            return (modal_stack.size > 0);
        }

        /**
         * {@inheritDoc}
         */
        public bool modal_proxy_valid (ModalProxy proxy) {
            return (proxy in modal_stack);
        }

        public void get_current_cursor_position (out int x, out int y) {
            Gdk.Display.get_default ().get_default_seat ().get_pointer ().get_position (null,
                out x, out y);
        }

        private void dim_parent_window (Meta.Window window, bool dim) {
            unowned var ancestor = window.find_root_ancestor ();
            if (ancestor != null && ancestor != window) {
                unowned var win = (Meta.WindowActor) ancestor.get_compositor_private ();
                // Can't rely on win.has_effects since other effects could be applied
                if (dim) {
                    if (window.window_type == Meta.WindowType.MODAL_DIALOG) {
                        var dark_effect = new Clutter.BrightnessContrastEffect ();
                        dark_effect.set_brightness (-0.4f);

                        win.add_effect_with_name ("dim-parent", dark_effect);
                    }
                } else if (win.get_effect ("dim-parent") != null) {
                    win.remove_effect_by_name ("dim-parent");
                }
            }
        }

        /**
         * {@inheritDoc}
         */
        public void perform_action (ActionType type) {
            unowned Meta.Display display = get_display ();
            var current = display.get_focus_window ();

            switch (type) {
                case ActionType.SHOW_WORKSPACE_VIEW:
                    if (workspace_view == null)
                        break;

                    if (workspace_view.is_opened ())
                        workspace_view.close ();
                    else
                        workspace_view.open ();
                    break;
                case ActionType.MAXIMIZE_CURRENT:
                    if (current == null || current.window_type != Meta.WindowType.NORMAL)
                        break;

                    var maximize_flags = current.get_maximized ();
                    if (Meta.MaximizeFlags.VERTICAL in maximize_flags || Meta.MaximizeFlags.HORIZONTAL in maximize_flags)
                        current.unmaximize (Meta.MaximizeFlags.HORIZONTAL | Meta.MaximizeFlags.VERTICAL);
                    else
                        current.maximize (Meta.MaximizeFlags.HORIZONTAL | Meta.MaximizeFlags.VERTICAL);
                    break;
                case ActionType.HIDE_CURRENT:
                    if (current != null && current.window_type == Meta.WindowType.NORMAL)
                        current.minimize ();
                    break;
                case ActionType.START_MOVE_CURRENT:
                    if (current != null && current.allows_move ())
                        current.begin_grab_op (Meta.GrabOp.KEYBOARD_MOVING, true, Gtk.get_current_event_time ());
                    break;
                case ActionType.START_RESIZE_CURRENT:
                    if (current != null && current.allows_resize ())
                        current.begin_grab_op (Meta.GrabOp.KEYBOARD_RESIZING_UNKNOWN, true, Gtk.get_current_event_time ());
                    break;
                case ActionType.TOGGLE_ALWAYS_ON_TOP_CURRENT:
                    if (current == null)
                        break;

                    if (current.is_above ())
                        current.unmake_above ();
                    else
                        current.make_above ();
                    break;
                case ActionType.TOGGLE_ALWAYS_ON_VISIBLE_WORKSPACE_CURRENT:
                    if (current == null)
                        break;

                    if (current.on_all_workspaces)
                        current.unstick ();
                    else
                        current.stick ();
                    break;
                case ActionType.MOVE_CURRENT_WORKSPACE_LEFT:
                    if (current != null) {
                        var wp = current.get_workspace ().get_neighbor (Meta.MotionDirection.LEFT);
                        if (wp != null)
                            current.change_workspace (wp);
                    }
                    break;
                case ActionType.MOVE_CURRENT_WORKSPACE_RIGHT:
                    if (current != null) {
                        var wp = current.get_workspace ().get_neighbor (Meta.MotionDirection.RIGHT);
                        if (wp != null)
                            current.change_workspace (wp);
                    }
                    break;
                case ActionType.CLOSE_CURRENT:
                    if (current != null && current.can_close ())
                        current.@delete (Gtk.get_current_event_time ());
                    break;
                case ActionType.OPEN_LAUNCHER:
                    try {
                        Process.spawn_command_line_async (
                            behavior_settings.get_string ("panel-main-menu-action")
                        );
                    } catch (Error e) {
                        warning (e.message);
                    }
                    break;
                case ActionType.WINDOW_OVERVIEW:
                    if (window_overview == null)
                        break;

                    if (window_overview.is_opened ())
                        window_overview.close ();
                    else
                        window_overview.open ();
                    break;
                case ActionType.WINDOW_OVERVIEW_ALL:
                    if (window_overview == null)
                        break;

                    if (window_overview.is_opened ())
                        window_overview.close ();
                    else {
                        var hints = new HashTable<string,Variant> (str_hash, str_equal);
                        hints.@set ("all-windows", true);
                        window_overview.open (hints);
                    }
                    break;
                case ActionType.SWITCH_TO_WORKSPACE_LAST:
                    unowned Meta.WorkspaceManager manager = display.get_workspace_manager ();
                    var workspace = manager.get_workspace_by_index (manager.get_n_workspaces () - 1);
                    workspace.activate (display.get_current_time ());
                    break;
                case ActionType.SCREENSHOT_CURRENT:
                    screenshot_current_window.begin ();
                    break;
                default:
                    warning ("Trying to run unknown action");
                    break;
            }
        }

        public override void show_window_menu (Meta.Window window, Meta.WindowMenuType menu, int x, int y) {
            switch (menu) {
                case Meta.WindowMenuType.WM:
                    if (daemon_proxy == null || window.get_window_type () == Meta.WindowType.NOTIFICATION) {
                        return;
                    }

                    WindowFlags flags = WindowFlags.NONE;
                    if (window.can_minimize ())
                        flags |= WindowFlags.CAN_HIDE;

                    if (window.can_maximize ())
                        flags |= WindowFlags.CAN_MAXIMIZE;

                    var maximize_flags = window.get_maximized ();
                    if (maximize_flags > 0) {
                        flags |= WindowFlags.IS_MAXIMIZED;

                        if (Meta.MaximizeFlags.VERTICAL in maximize_flags && !(Meta.MaximizeFlags.HORIZONTAL in maximize_flags)) {
                            flags |= WindowFlags.IS_TILED;
                        }
                    }

                    if (window.allows_move ())
                        flags |= WindowFlags.ALLOWS_MOVE;

                    if (window.allows_resize ())
                        flags |= WindowFlags.ALLOWS_RESIZE;

                    if (window.is_above ())
                        flags |= WindowFlags.ALWAYS_ON_TOP;

                    if (window.on_all_workspaces)
                        flags |= WindowFlags.ON_ALL_WORKSPACES;

                    if (window.can_close ())
                        flags |= WindowFlags.CAN_CLOSE;

                    daemon_proxy.show_window_menu.begin (flags, x, y, (obj, res) => {
                        try {
                            ((Daemon) obj).show_window_menu.end (res);
                        } catch (Error e) {
                            message ("Error invoking MenuManager: %s", e.message);
                        }
                    });
                    break;
                case Meta.WindowMenuType.APP:
                    // FIXME we don't have any sort of app menus
                    break;
            }
        }

        public override void show_tile_preview (Meta.Window window, Meta.Rectangle tile_rect, int tile_monitor_number) {
            if (tile_preview == null) {
                tile_preview = new Clutter.Actor ();
                var rgba = InternalUtils.get_theme_accent_color ();
                tile_preview.background_color = {
                    (uint8)(255.0 * rgba.red),
                    (uint8)(255.0 * rgba.green),
                    (uint8)(255.0 * rgba.blue),
                    (uint8)(255.0 * rgba.alpha)
                };
                tile_preview.opacity = 0U;

                window_group.add_child (tile_preview);
            } else if (tile_preview.is_visible ()) {
                float width, height, x, y;
                tile_preview.get_position (out x, out y);
                tile_preview.get_size (out width, out height);

                if ((tile_rect.width == width && tile_rect.height == height && tile_rect.x == x && tile_rect.y == y)
                    || tile_preview.get_transition ("size") != null) {
                    return;
                }
            }

            unowned Meta.WindowActor window_actor = window.get_compositor_private () as Meta.WindowActor;
            window_group.set_child_below_sibling (tile_preview, window_actor);

            var duration = AnimationDuration.SNAP / 2U;

            var rect = window.get_frame_rect ();
            tile_preview.set_position (rect.x, rect.y);
            tile_preview.set_size (rect.width, rect.height);
            tile_preview.show ();

            if (enable_animations) {
                tile_preview.save_easing_state ();
                tile_preview.set_easing_mode (Clutter.AnimationMode.EASE_IN_OUT_QUAD);
                tile_preview.set_easing_duration (duration);
                tile_preview.opacity = 255U;
                tile_preview.set_position (tile_rect.x, tile_rect.y);
                tile_preview.set_size (tile_rect.width, tile_rect.height);
                tile_preview.restore_easing_state ();
            } else {
                tile_preview.opacity = 255U;
            }
        }

        public override void hide_tile_preview () {
            if (tile_preview != null) {
                tile_preview.remove_all_transitions ();
                tile_preview.opacity = 0U;
                tile_preview.hide ();
                tile_preview = null;
            }
        }

        public override void show_window_menu_for_rect (Meta.Window window, Meta.WindowMenuType menu, Meta.Rectangle rect) {
            show_window_menu (window, menu, rect.x, rect.y);
        }

        /*
         * effects
         */

        void handle_fullscreen_window (Meta.Window window, Meta.SizeChange which_change) {
            // Only handle windows which are located on the primary monitor
            if (!window.is_on_primary_monitor () || !behavior_settings.get_boolean ("move-fullscreened-workspace"))
                return;

            // Due to how this is implemented, by relying on the functionality
            // offered by the dynamic workspace handler, let's just bail out
            // if that's not available.
            if (!Meta.Prefs.get_dynamic_workspaces ())
                return;

            unowned Meta.Display display = get_display ();
            var time = display.get_current_time ();
            unowned Meta.Workspace win_ws = window.get_workspace ();
            unowned Meta.WorkspaceManager manager = display.get_workspace_manager ();

            if (which_change == Meta.SizeChange.FULLSCREEN) {
                // Do nothing if the current workspace would be empty
                if (Utils.get_n_windows (win_ws) <= 1)
                    return;

                var old_ws_index = win_ws.index ();
                var new_ws_index = old_ws_index + 1;
                InternalUtils.insert_workspace_with_window (new_ws_index, window);

                var new_ws_obj = manager.get_workspace_by_index (new_ws_index);
                window.change_workspace (new_ws_obj);
                new_ws_obj.activate_with_focus (window, time);

                ws_assoc.insert (window, old_ws_index);
            } else if (ws_assoc.contains (window)) {
                var old_ws_index = ws_assoc.get (window);
                var new_ws_index = win_ws.index ();

                if (new_ws_index != old_ws_index && old_ws_index < manager.get_n_workspaces ()) {
                    var old_ws_obj = manager.get_workspace_by_index (old_ws_index);
                    window.change_workspace (old_ws_obj);
                    old_ws_obj.activate_with_focus (window, time);
                }

                ws_assoc.remove (window);
            }
        }

        // must wait for size_changed to get updated frame_rect
        // as which_change is not passed to size_changed, save it as instance variable
        public override void size_change (Meta.WindowActor actor, Meta.SizeChange which_change_local, Meta.Rectangle old_frame_rect, Meta.Rectangle old_buffer_rect) {
            which_change = which_change_local;
            old_rect_size_change = old_frame_rect;
        }

        // size_changed gets called after frame_rect has updated
        public override void size_changed (Meta.WindowActor actor) {
            if (which_change == null) {
                return;
            }

            Meta.SizeChange? which_change_local = which_change;
            which_change = null;

            unowned Meta.Window window = actor.get_meta_window ();
            var new_rect = window.get_frame_rect ();

            switch (which_change_local) {
                case Meta.SizeChange.MAXIMIZE:
                    // don't animate resizing of two tiled windows with mouse drag
                    if (window.get_tile_match () != null && !window.maximized_horizontally) {
                        var old_end = old_rect_size_change.x + old_rect_size_change.width;
                        var new_end = new_rect.x + new_rect.width;

                        // a tiled window is just resized (and not moved) if its start_x or its end_x stays the same
                        if (old_rect_size_change.x == new_rect.x || old_end == new_end) {
                            break;
                        }
                    }
                    maximize (actor, new_rect.x, new_rect.y, new_rect.width, new_rect.height);
                    break;
                case Meta.SizeChange.UNMAXIMIZE:
                    unmaximize (actor, new_rect.x, new_rect.y, new_rect.width, new_rect.height);
                    break;
                case Meta.SizeChange.FULLSCREEN:
                case Meta.SizeChange.UNFULLSCREEN:
                    handle_fullscreen_window (window, which_change_local);
                    break;
            }

            size_change_completed (actor);
        }

        public override void minimize (Meta.WindowActor actor) {
            var duration = AnimationDuration.HIDE;

            if (!enable_animations
                || duration == 0
                || actor.get_meta_window ().window_type != Meta.WindowType.NORMAL) {
                minimize_completed (actor);
                return;
            }

            kill_window_effects (actor);
            minimizing.add (actor);

            int width, height;
            get_display ().get_size (out width, out height);

            Meta.Rectangle icon = {};
            if (actor.get_meta_window ().get_icon_geometry (out icon)) {
                // Fix icon position and size according to ui scaling factor.
                int ui_scale = InternalUtils.get_ui_scaling_factor ();
                icon.x *= ui_scale;
                icon.y *= ui_scale;
                icon.width *= ui_scale;
                icon.height *= ui_scale;

                float scale_x = (float)icon.width / actor.width;
                float scale_y = (float)icon.height / actor.height;
                float anchor_x = (float)(actor.x - icon.x) / (icon.width - actor.width);
                float anchor_y = (float)(actor.y - icon.y) / (icon.height - actor.height);
                actor.set_pivot_point (anchor_x, anchor_y);

                actor.save_easing_state ();
                actor.set_easing_mode (Clutter.AnimationMode.EASE_IN_EXPO);
                actor.set_easing_duration (duration);
                actor.set_scale (scale_x, scale_y);
                actor.opacity = 0U;
                actor.restore_easing_state ();

                ulong minimize_handler_id = 0UL;
                minimize_handler_id = actor.transitions_completed.connect (() => {
                    actor.disconnect (minimize_handler_id);
                    actor.set_pivot_point (0.0f, 0.0f);
                    actor.set_scale (1.0f, 1.0f);
                    actor.opacity = 255U;
                    minimize_completed (actor);
                    minimizing.remove (actor);
                });

            } else {
                actor.set_pivot_point (0.5f, 1.0f);

                actor.save_easing_state ();
                actor.set_easing_mode (Clutter.AnimationMode.EASE_IN_EXPO);
                actor.set_easing_duration (duration);
                actor.set_scale (0.0f, 0.0f);
                actor.opacity = 0U;
                actor.restore_easing_state ();

                ulong minimize_handler_id = 0UL;
                minimize_handler_id = actor.transitions_completed.connect (() => {
                    actor.disconnect (minimize_handler_id);
                    actor.set_pivot_point (0.0f, 0.0f);
                    actor.set_scale (1.0f, 1.0f);
                    actor.opacity = 255U;
                    minimize_completed (actor);
                    minimizing.remove (actor);
                });
            }
        }

        void maximize (Meta.WindowActor actor, int ex, int ey, int ew, int eh) {
            var duration = AnimationDuration.SNAP;

            if (!enable_animations
                || duration == 0) {
                return;
            }

            kill_window_effects (actor);

            var window = actor.get_meta_window ();
            if (window.maximized_horizontally && behavior_settings.get_boolean ("move-maximized-workspace")) {
                move_window_to_next_ws (window);
            }

            if (window.window_type == Meta.WindowType.NORMAL) {
                Meta.Rectangle fallback = { (int) actor.x, (int) actor.y, (int) actor.width, (int) actor.height };
                var window_geometry = WindowListener.get_default ().get_unmaximized_state_geometry (window);
                var old_inner_rect = window_geometry != null ? window_geometry.inner : fallback;
                var old_outer_rect = window_geometry != null ? window_geometry.outer : fallback;

                var old_actor = Utils.get_window_actor_snapshot (actor, old_inner_rect, old_outer_rect);
                if (old_actor == null) {
                    return;
                }

                maximizing.add (actor);
                old_actor.set_position (old_inner_rect.x, old_inner_rect.y);

                ui_group.add_child (old_actor);

                // FIMXE that's a hacky part. There is a short moment right after maximized_completed
                //       where the texture is screwed up and shows things it's not supposed to show,
                //       resulting in flashing. Waiting here transparently shortly fixes that issue. There
                //       appears to be no signal that would inform when that moment happens.
                //       We can't spend arbitrary amounts of time transparent since the overlay fades away,
                //       about a third has proven to be a solid time. So this fix will only apply for
                //       durations >= FLASH_PREVENT_TIMEOUT*3
                const int FLASH_PREVENT_TIMEOUT = 80;
                var delay = 0;
                if (FLASH_PREVENT_TIMEOUT <= duration / 3) {
                    actor.opacity = 0;
                    delay = FLASH_PREVENT_TIMEOUT;
                    Timeout.add (FLASH_PREVENT_TIMEOUT, () => {
                        actor.opacity = 255;
                        return false;
                    });
                }

                var scale_x = (double) ew / old_inner_rect.width;
                var scale_y = (double) eh / old_inner_rect.height;

                old_actor.save_easing_state ();
                old_actor.set_easing_mode (Clutter.AnimationMode.EASE_IN_OUT_QUAD);
                old_actor.set_easing_duration (duration);
                old_actor.set_position (ex, ey);
                old_actor.set_scale (scale_x, scale_y);

                // the opacity animation is special, since we have to wait for the
                // FLASH_PREVENT_TIMEOUT to be done before we can safely fade away
                old_actor.save_easing_state ();
                old_actor.set_easing_delay (delay);
                old_actor.set_easing_duration (duration - delay);
                old_actor.opacity = 0;
                old_actor.restore_easing_state ();

                ulong maximize_old_handler_id = 0UL;
                maximize_old_handler_id = old_actor.transitions_completed.connect (() => {
                    old_actor.disconnect (maximize_old_handler_id);
                    old_actor.destroy ();
                    actor.set_translation (0.0f, 0.0f, 0.0f);
                });

                old_actor.restore_easing_state ();

                actor.set_pivot_point (0.0f, 0.0f);
                actor.set_translation (old_inner_rect.x - ex, old_inner_rect.y - ey, 0.0f);
                actor.set_scale (1.0f / scale_x, 1.0f / scale_y);

                actor.save_easing_state ();
                actor.set_easing_mode (Clutter.AnimationMode.EASE_IN_OUT_QUAD);
                actor.set_easing_duration (duration);
                actor.set_scale (1.0f, 1.0f);
                actor.set_translation (0.0f, 0.0f, 0.0f);
                actor.restore_easing_state ();

                ulong handler_id = 0UL;
                handler_id = actor.transitions_completed.connect (() => {
                    actor.disconnect (handler_id);
                    maximizing.remove (actor);
                });
            }
        }

        public override void unminimize (Meta.WindowActor actor) {
            if (!enable_animations) {
                actor.show ();
                unminimize_completed (actor);
                return;
            }

            var window = actor.get_meta_window ();

            actor.remove_all_transitions ();
            actor.show ();

            switch (window.window_type) {
                case Meta.WindowType.NORMAL:
                    var duration = AnimationDuration.HIDE;
                    if (duration == 0) {
                        unminimize_completed (actor);
                        return;
                    }

                    unminimizing.add (actor);

                    actor.set_pivot_point (0.5f, 1.0f);
                    actor.set_scale (0.01f, 0.1f);
                    actor.opacity = 0U;

                    actor.save_easing_state ();
                    actor.set_easing_mode (Clutter.AnimationMode.EASE_OUT_EXPO);
                    actor.set_easing_duration (duration);
                    actor.set_scale (1.0f, 1.0f);
                    actor.opacity = 255U;
                    actor.restore_easing_state ();

                    ulong unminimize_handler_id = 0UL;
                    unminimize_handler_id = actor.transitions_completed.connect (() => {
                        actor.disconnect (unminimize_handler_id);
                        unminimizing.remove (actor);
                        unminimize_completed (actor);
                    });

                    break;
                default:
                    unminimize_completed (actor);
                    break;
            }
        }

        public override void map (Meta.WindowActor actor) {
            var window = actor.get_meta_window ();

            // Notifications are a special case and have to be always be handled
            // regardless of the animation setting
            if (!enable_animations && window.window_type != Meta.WindowType.NOTIFICATION) {
                actor.show ();
                map_completed (actor);

                if (InternalUtils.get_window_is_normal (window) && window.get_layer () == Meta.StackLayer.BOTTOM) {
                    show_bottom_stack_window (window);
                }

                return;
            }

            actor.remove_all_transitions ();
            actor.show ();

            switch (window.window_type) {
                case Meta.WindowType.NORMAL:
                    var duration = AnimationDuration.HIDE;
                    if (duration == 0) {
                        map_completed (actor);
                        return;
                    }

                    mapping.add (actor);

                    if (window.maximized_vertically || window.maximized_horizontally) {
                        var outer_rect = window.get_frame_rect ();
                        actor.set_position (outer_rect.x, outer_rect.y);
                    }

                    actor.set_pivot_point (0.5f, 1.0f);
                    actor.set_scale (0.01f, 0.1f);
                    actor.opacity = 0;

                    actor.save_easing_state ();
                    actor.set_easing_mode (Clutter.AnimationMode.EASE_OUT_EXPO);
                    actor.set_easing_duration (duration);
                    actor.set_scale (1.0f, 1.0f);
                    actor.opacity = 255U;
                    actor.restore_easing_state ();

                    ulong map_handler_id = 0UL;
                    map_handler_id = actor.transitions_completed.connect (() => {
                        actor.disconnect (map_handler_id);
                        mapping.remove (actor);
                        map_completed (actor);

                        if (window.get_layer () == Meta.StackLayer.BOTTOM) {
                            show_bottom_stack_window (window);
                        }
                    });
                    break;
                case Meta.WindowType.MENU:
                case Meta.WindowType.DROPDOWN_MENU:
                case Meta.WindowType.POPUP_MENU:
                    var duration = AnimationDuration.MENU_MAP;
                    if (duration == 0) {
                        map_completed (actor);
                        return;
                    }

                    mapping.add (actor);

                    actor.set_pivot_point (0.5f, 0.5f);
                    actor.set_pivot_point_z (0.2f);
                    actor.set_scale (0.9f, 0.9f);
                    actor.opacity = 0;

                    actor.save_easing_state ();
                    actor.set_easing_mode (Clutter.AnimationMode.EASE_OUT_QUAD);
                    actor.set_easing_duration (duration);
                    actor.set_scale (1.0f, 1.0f);
                    actor.opacity = 255U;
                    actor.restore_easing_state ();

                    ulong map_handler_id = 0UL;
                    map_handler_id = actor.transitions_completed.connect (() => {
                        actor.disconnect (map_handler_id);
                        mapping.remove (actor);
                        map_completed (actor);
                    });
                    break;
                case Meta.WindowType.MODAL_DIALOG:
                case Meta.WindowType.DIALOG:

                    mapping.add (actor);

                    actor.set_pivot_point (0.5f, 0.5f);
                    actor.set_scale (1.05f, 1.05f);
                    actor.opacity = 0;

                    actor.save_easing_state ();
                    actor.set_easing_mode (Clutter.AnimationMode.EASE_OUT_QUAD);
                    actor.set_easing_duration (200);
                    actor.set_scale (1.0f, 1.0f);
                    actor.opacity = 255U;
                    actor.restore_easing_state ();

                    ulong map_handler_id = 0UL;
                    map_handler_id = actor.transitions_completed.connect (() => {
                        actor.disconnect (map_handler_id);
                        mapping.remove (actor);
                        map_completed (actor);

                        if (window.get_layer () == Meta.StackLayer.BOTTOM) {
                            show_bottom_stack_window (window);
                        }
                    });

                    dim_parent_window (window, true);

                    break;
                case Meta.WindowType.NOTIFICATION:
                    notification_stack.show_notification (actor, enable_animations);
                    map_completed (actor);

                    break;
                default:
                    map_completed (actor);
                    break;
            }
        }

        public override void destroy (Meta.WindowActor actor) {
            var window = actor.get_meta_window ();

            ws_assoc.remove (window);

            if (!enable_animations && window.window_type != Meta.WindowType.NOTIFICATION) {
                destroy_completed (actor);

                if (window.window_type == Meta.WindowType.NORMAL) {
                    Utils.clear_window_cache (window);
                }

                return;
            }

            actor.remove_all_transitions ();

            switch (window.window_type) {
                case Meta.WindowType.NORMAL:
                    var duration = AnimationDuration.CLOSE;
                    if (duration == 0) {
                        destroy_completed (actor);
                        return;
                    }

                    destroying.add (actor);

                    actor.set_pivot_point (0.5f, 0.5f);
                    actor.show ();

                    actor.save_easing_state ();
                    actor.set_easing_mode (Clutter.AnimationMode.LINEAR);
                    actor.set_easing_duration (duration);
                    actor.set_scale (0.8f, 0.8f);
                    actor.opacity = 0U;
                    actor.restore_easing_state ();

                    ulong destroy_handler_id = 0UL;
                    destroy_handler_id = actor.transitions_completed.connect (() => {
                        actor.disconnect (destroy_handler_id);
                        destroying.remove (actor);
                        destroy_completed (actor);
                        Utils.clear_window_cache (window);
                    });
                    break;
                case Meta.WindowType.MODAL_DIALOG:
                case Meta.WindowType.DIALOG:
                    destroying.add (actor);

                    actor.set_pivot_point (0.5f, 0.5f);
                    actor.save_easing_state ();
                    actor.set_easing_mode (Clutter.AnimationMode.EASE_OUT_QUAD);
                    actor.set_easing_duration (150);
                    actor.set_scale (1.05f, 1.05f);
                    actor.opacity = 0U;
                    actor.restore_easing_state ();

                    ulong destroy_handler_id = 0UL;
                    destroy_handler_id = actor.transitions_completed.connect (() => {
                        actor.disconnect (destroy_handler_id);
                        destroying.remove (actor);
                        destroy_completed (actor);
                    });

                    dim_parent_window (window, false);

                    break;
                case Meta.WindowType.MENU:
                case Meta.WindowType.DROPDOWN_MENU:
                case Meta.WindowType.POPUP_MENU:
                    var duration = AnimationDuration.MENU_MAP;
                    if (duration == 0) {
                        destroy_completed (actor);
                        return;
                    }

                    destroying.add (actor);
                    actor.save_easing_state ();
                    actor.set_easing_mode (Clutter.AnimationMode.EASE_OUT_QUAD);
                    actor.set_easing_duration (duration);
                    actor.set_scale (0.8f, 0.8f);
                    actor.opacity = 0U;
                    actor.restore_easing_state ();

                    ulong destroy_handler_id = 0UL;
                    destroy_handler_id = actor.transitions_completed.connect (() => {
                        actor.disconnect (destroy_handler_id);
                        destroying.remove (actor);
                        destroy_completed (actor);
                    });
                    break;
                case Meta.WindowType.NOTIFICATION:
                    if (enable_animations) {
                        destroying.add (actor);
                    }

                    notification_stack.destroy_notification (actor, enable_animations);

                    if (enable_animations) {
                        ulong destroy_handler_id = 0UL;
                        destroy_handler_id = actor.transitions_completed.connect (() => {
                            actor.disconnect (destroy_handler_id);
                            destroying.remove (actor);
                            destroy_completed (actor);
                        });
                    } else {
                        destroy_completed (actor);
                    }

                    break;
                default:
                    destroy_completed (actor);
                    break;
            }
        }

        void unmaximize (Meta.WindowActor actor, int ex, int ey, int ew, int eh) {
            var duration = AnimationDuration.SNAP;
            if (!enable_animations
                || duration == 0) {
                return;
            }

            kill_window_effects (actor);
            var window = actor.get_meta_window ();

            if (behavior_settings.get_boolean ("move-maximized-workspace")) {
                move_window_to_old_ws (window);
            }

            if (window.window_type == Meta.WindowType.NORMAL) {
                float offset_x, offset_y, offset_width, offset_height;
                var unmaximized_window_geometry = WindowListener.get_default ().get_unmaximized_state_geometry (window);

                if (unmaximized_window_geometry != null) {
                    offset_x = unmaximized_window_geometry.outer.x - unmaximized_window_geometry.inner.x;
                    offset_y = unmaximized_window_geometry.outer.y - unmaximized_window_geometry.inner.y;
                    offset_width = unmaximized_window_geometry.outer.width - unmaximized_window_geometry.inner.width;
                    offset_height = unmaximized_window_geometry.outer.height - unmaximized_window_geometry.inner.height;
                } else {
                    offset_x = 0;
                    offset_y = 0;
                    offset_width = 0;
                    offset_height = 0;
                }

                Meta.Rectangle old_rect = { (int) actor.x, (int) actor.y, (int) actor.width, (int) actor.height };
                var old_actor = Utils.get_window_actor_snapshot (actor, old_rect, old_rect);

                if (old_actor == null) {
                    return;
                }

                unmaximizing.add (actor);

                old_actor.set_position (old_rect.x, old_rect.y);

                ui_group.add_child (old_actor);

                var scale_x = (float) ew / old_rect.width;
                var scale_y = (float) eh / old_rect.height;

                old_actor.save_easing_state ();
                old_actor.set_easing_mode (Clutter.AnimationMode.EASE_IN_OUT_QUAD);
                old_actor.set_easing_duration (duration);
                old_actor.set_position (ex, ey);
                old_actor.set_scale (scale_x, scale_y);
                old_actor.opacity = 0U;
                old_actor.restore_easing_state ();

                ulong unmaximize_old_handler_id = 0UL;
                unmaximize_old_handler_id = old_actor.transitions_completed.connect (() => {
                    old_actor.disconnect (unmaximize_old_handler_id);
                    old_actor.destroy ();
                });

                var maximized_x = actor.x;
                var maximized_y = actor.y;
                actor.set_pivot_point (0.0f, 0.0f);
                actor.set_position (ex, ey);
                actor.set_translation (-ex + offset_x * (1.0f / scale_x - 1.0f) + maximized_x, -ey + offset_y * (1.0f / scale_y - 1.0f) + maximized_y, 0.0f);
                actor.set_scale (1.0f / scale_x, 1.0f / scale_y);

                actor.save_easing_state ();
                actor.set_easing_mode (Clutter.AnimationMode.EASE_IN_OUT_QUAD);
                actor.set_easing_duration (duration);
                actor.set_scale (1.0f, 1.0f);
                actor.set_translation (0.0f, 0.0f, 0.0f);
                actor.restore_easing_state ();

                ulong handler_id = 0UL;
                handler_id = actor.transitions_completed.connect (() => {
                    actor.disconnect (handler_id);
                    unmaximizing.remove (actor);
                });
            }
        }

        void move_window_to_next_ws (Meta.Window window) {
            unowned Meta.Workspace win_ws = window.get_workspace ();

            // Do nothing if the current workspace would be empty
            if (Utils.get_n_windows (win_ws) <= 1) {
                return;
            }

            // Do nothing if window is not on primary monitor
            if (!window.is_on_primary_monitor ()) {
                return;
            }

            var old_ws_index = win_ws.index ();
            var new_ws_index = old_ws_index + 1;
            InternalUtils.insert_workspace_with_window (new_ws_index, window);

            unowned Meta.Display display = get_display ();
            var time = display.get_current_time ();
            var new_ws_obj = display.get_workspace_manager ().get_workspace_by_index (new_ws_index);
            window.change_workspace (new_ws_obj);
            new_ws_obj.activate_with_focus (window, time);

            ws_assoc.insert (window, old_ws_index);
        }

        private void move_window_to_old_ws (Meta.Window window) {
            unowned Meta.Workspace win_ws = window.get_workspace ();

            // Do nothing if the current workspace is populated with other windows
            if (Utils.get_n_windows (win_ws) > 1) {
                return;
            }

            if (!ws_assoc.contains (window)) {
                return;
            }

            var old_ws_index = ws_assoc.get (window);
            var new_ws_index = win_ws.index ();

            unowned Meta.Display display = get_display ();
            unowned Meta.WorkspaceManager workspace_manager = display.get_workspace_manager ();
            if (new_ws_index != old_ws_index && old_ws_index < workspace_manager.get_n_workspaces ()) {
                uint time = display.get_current_time ();
                var old_ws_obj = workspace_manager.get_workspace_by_index (old_ws_index);
                window.change_workspace (old_ws_obj);
                old_ws_obj.activate_with_focus (window, time);
            }

            ws_assoc.remove (window);
        }

        // Cancel attached animation of an actor and reset it
        bool end_animation (ref Gee.HashSet<Meta.WindowActor> list, Meta.WindowActor actor) {
            if (!list.contains (actor))
                return false;

            if (actor.is_destroyed ()) {
                list.remove (actor);
                return false;
            }

            actor.remove_all_transitions ();
            actor.opacity = 255U;
            actor.set_scale (1.0f, 1.0f);
            actor.rotation_angle_x = 0.0f;
            actor.set_pivot_point (0.0f, 0.0f);

            list.remove (actor);
            return true;
        }

        public override void kill_window_effects (Meta.WindowActor actor) {
            if (end_animation (ref mapping, actor))
                map_completed (actor);
            if (end_animation (ref unminimizing, actor))
                unminimize_completed (actor);
            if (end_animation (ref minimizing, actor))
                minimize_completed (actor);
            if (end_animation (ref destroying, actor))
                destroy_completed (actor);

            end_animation (ref unmaximizing, actor);
            end_animation (ref maximizing, actor);
        }

        /*workspace switcher*/
        List<Clutter.Actor>? windows;
        List<Clutter.Actor>? parents;
        List<Clutter.Actor>? tmp_actors;

        public override void switch_workspace (int from, int to, Meta.MotionDirection direction) {
            if (!enable_animations
                || AnimationDuration.WORKSPACE_SWITCH == 0
                || (direction != Meta.MotionDirection.LEFT && direction != Meta.MotionDirection.RIGHT)
                || animating_switch_workspace) {
                animating_switch_workspace = false;
                switch_workspace_completed ();
                return;
            }

            animating_switch_workspace = true;

            float screen_width, screen_height;
            unowned Meta.Display display = get_display ();
            var primary = display.get_primary_monitor ();
            var move_primary_only = InternalUtils.workspaces_only_on_primary ();
            var monitor_geom = display.get_monitor_geometry (primary);
            var clone_offset_x = move_primary_only ? monitor_geom.x : 0.0f;
            var clone_offset_y = move_primary_only ? monitor_geom.y : 0.0f;

            display.get_size (out screen_width, out screen_height);

            unowned Meta.WorkspaceManager manager = display.get_workspace_manager ();
            unowned Meta.Workspace workspace_from = manager.get_workspace_by_index (from);
            unowned Meta.Workspace workspace_to = manager.get_workspace_by_index (to);

            var main_container = new Clutter.Actor ();
            var background_actor = new Clutter.Clone (system_background.background_actor);
            var static_windows = new Clutter.Actor ();
            var in_group = new Clutter.Actor ();
            var out_group = new Clutter.Actor ();
            windows = new List<Meta.WindowActor> ();
            parents = new List<Clutter.Actor> ();
            tmp_actors = new List<Clutter.Clone> ();

            tmp_actors.prepend (main_container);
            tmp_actors.prepend (background_actor);
            tmp_actors.prepend (in_group);
            tmp_actors.prepend (out_group);
            tmp_actors.prepend (static_windows);

            window_group.add_child (main_container);

            // prepare wallpaper
            Clutter.Actor wallpaper;
            if (move_primary_only) {
                unowned var background = background_group.get_child_at_index (primary);
                background.hide ();
                wallpaper = new Clutter.Clone (background);
            } else {
                background_group.hide ();
                wallpaper = new Clutter.Clone (background_group);
            }
            tmp_actors.prepend (wallpaper);

            var wallpaper_clone = new Clutter.Clone (wallpaper);
            tmp_actors.prepend (wallpaper_clone);

            // pack all containers
            main_container.add_child (background_actor);
            main_container.add_child (wallpaper);
            main_container.add_child (wallpaper_clone);
            main_container.add_child (out_group);
            main_container.add_child (in_group);
            main_container.add_child (static_windows);

            // if we have a move action, pack that window to the static ones
            if (moving != null) {
                var moving_actor = (Meta.WindowActor) moving.get_compositor_private ();

                windows.prepend (moving_actor);
                parents.prepend (moving_actor.get_parent ());

                moving_actor.set_translation (-clone_offset_x, -clone_offset_y, 0);
                clutter_actor_reparent (moving_actor, static_windows);
            }

            var to_has_fullscreened = false;
            var from_has_fullscreened = false;
            var docks = new List<Meta.WindowActor> ();

            // collect all windows and put them in the appropriate containers
            foreach (unowned Meta.WindowActor actor in display.get_window_actors ()) {
                if (actor.is_destroyed ())
                    continue;

                unowned Meta.Window window = actor.get_meta_window ();

                if (!window.showing_on_its_workspace () ||
                    (move_primary_only && window.get_monitor () != primary) ||
                    (moving != null && window == moving))
                    continue;

                if (window.is_on_all_workspaces ()) {
                    // only collect docks here that need to be displayed on both workspaces
                    // all other windows will be collected below
                    if (window.window_type == Meta.WindowType.DOCK) {
                        docks.prepend (actor);
                    } else {
                        // windows that are on all workspaces will be faded out and back in
                        windows.prepend (actor);
                        parents.prepend (actor.get_parent ());

                        if (window.window_type == Meta.WindowType.NOTIFICATION) {
                            reparent_notification_window (actor, static_windows);
                        } else {
                            clutter_actor_reparent (actor, static_windows);
                            actor.set_translation (-clone_offset_x, -clone_offset_y, 0);
                            actor.save_easing_state ();
                            actor.set_easing_duration (300);
                            actor.opacity = 0;
                            actor.restore_easing_state ();
                        }
                    }

                    continue;
                }

                if (window.get_workspace () == workspace_from) {
                    windows.append (actor);
                    parents.append (actor.get_parent ());
                    actor.set_translation (-clone_offset_x, -clone_offset_y, 0);
                    clutter_actor_reparent (actor, out_group);

                    if (window.fullscreen)
                        from_has_fullscreened = true;

                } else if (window.get_workspace () == workspace_to) {
                    windows.append (actor);
                    parents.append (actor.get_parent ());
                    actor.set_translation (-clone_offset_x, -clone_offset_y, 0);
                    clutter_actor_reparent (actor, in_group);

                    if (window.fullscreen)
                        to_has_fullscreened = true;

                }
            }

            // make sure we don't add docks when there are fullscreened
            // windows on one of the groups. Simply raising seems not to
            // work, mutter probably reverts the order internally to match
            // the display stack
            foreach (var window in docks) {
                if (!to_has_fullscreened) {
                    var clone = new SafeWindowClone (window.get_meta_window ()) {
                        x = window.x - clone_offset_x,
                        y = window.y - clone_offset_y
                    };

                    in_group.add_child (clone);
                    tmp_actors.prepend (clone);
                }

                if (!from_has_fullscreened) {
                    windows.prepend (window);
                    parents.prepend (window.get_parent ());
                    window.set_translation (-clone_offset_x, -clone_offset_y, 0.0f);

                    clutter_actor_reparent (window, out_group);
                }
            }

            main_container.clip_to_allocation = true;
            main_container.x = move_primary_only ? monitor_geom.x : 0.0f;
            main_container.y = move_primary_only ? monitor_geom.y : 0.0f;
            main_container.width = move_primary_only ? monitor_geom.width : screen_width;
            main_container.height = move_primary_only ? monitor_geom.height : screen_height;

            var x2 = move_primary_only ? monitor_geom.width : screen_width;
            x2 += WORKSPACE_GAP * InternalUtils.get_ui_scaling_factor ();
            if (direction == Meta.MotionDirection.RIGHT)
                x2 = -x2;

            out_group.x = 0.0f;
            wallpaper.x = 0.0f;
            wallpaper.y += clone_offset_y;
            in_group.x = -x2;
            wallpaper_clone.x = -x2;
            wallpaper_clone.y += clone_offset_y;
            wallpaper.set_translation (-clone_offset_x, 0.0f, 0.0f);
            wallpaper_clone.set_translation (-clone_offset_x, 0.0f, 0.0f);

            // The wallpapers need to move upwards inside the container to match their
            // original position before/after the transition.
            if (move_primary_only) {
                wallpaper.y = -monitor_geom.y;
                wallpaper_clone.y = -monitor_geom.y;
            }

            in_group.clip_to_allocation = out_group.clip_to_allocation = true;
            in_group.width = out_group.width = move_primary_only ? monitor_geom.width : screen_width;
            in_group.height = out_group.height = move_primary_only ? monitor_geom.height : screen_height;

            var animation_mode = Clutter.AnimationMode.EASE_OUT_CUBIC;

            GestureTracker.OnUpdate on_animation_update = (percentage) => {
                var x_out = GestureTracker.animation_value (0.0f, x2, percentage, true);
                var x_in = GestureTracker.animation_value (-x2, 0.0f, percentage, true);

                out_group.x = x_out;
                in_group.x = x_in;

                wallpaper.x = x_out;
                wallpaper_clone.x = x_in;
            };

            GestureTracker.OnEnd on_animation_end = (percentage, cancel_action, calculated_duration) => {
                if (switch_workspace_with_gesture && (percentage == 1 || percentage == 0)) {
                    switch_workspace_animation_finished (direction, cancel_action);
                    return;
                }

                int duration = switch_workspace_with_gesture
                    ? calculated_duration
                    : AnimationDuration.WORKSPACE_SWITCH_MIN;

                out_group.set_easing_mode (animation_mode);
                out_group.set_easing_duration (duration);
                in_group.set_easing_mode (animation_mode);
                in_group.set_easing_duration (duration);
                wallpaper_clone.set_easing_mode (animation_mode);
                wallpaper_clone.set_easing_duration (duration);

                wallpaper.save_easing_state ();
                wallpaper.set_easing_mode (animation_mode);
                wallpaper.set_easing_duration (duration);

                out_group.x = cancel_action ? 0.0f : x2;
                in_group.x = cancel_action ? -x2 : 0.0f;

                wallpaper.x = cancel_action ? 0.0f : x2;
                wallpaper_clone.x = cancel_action ? -x2 : 0.0f;
                wallpaper.restore_easing_state ();

                var transition = in_group.get_transition ("x");
                if (transition != null) {
                    transition.completed.connect (() => {
                        switch_workspace_animation_finished (direction, cancel_action);
                    });
                } else {
                    switch_workspace_animation_finished (direction, cancel_action);
                }
            };

            if (!switch_workspace_with_gesture) {
                on_animation_end (1, false, 0);
            } else {
                gesture_tracker.connect_handlers (null, (owned) on_animation_update, (owned) on_animation_end);
            }
        }

        private void switch_workspace_animation_finished (Meta.MotionDirection animation_direction,
                bool cancel_action) {
            end_switch_workspace ();
            switch_workspace_with_gesture = false;
            animating_switch_workspace = cancel_action;

            if (cancel_action) {
                var cancel_direction = (animation_direction == Meta.MotionDirection.LEFT)
                    ? Meta.MotionDirection.RIGHT
                    : Meta.MotionDirection.LEFT;
                unowned Meta.Display display = get_display ();
                var active_workspace = display.get_workspace_manager ().get_active_workspace ();
                var neighbor = active_workspace.get_neighbor (cancel_direction);
                neighbor.activate (display.get_current_time ());
            }
        }

        void end_switch_workspace () {
            if (windows == null || parents == null)
                return;

            unowned Meta.Display display = get_display ();
            var active_workspace = display.get_workspace_manager ().get_active_workspace ();

            // Show the real wallpaper again
            var primary = display.get_primary_monitor ();
            var move_primary_only = InternalUtils.workspaces_only_on_primary ();
            if (move_primary_only) {
                unowned var background = background_group.get_child_at_index (primary);
                background.show ();
            } else {
                background_group.show ();
            }

            for (var i = 0; i < windows.length (); i++) {
                var actor = windows.nth_data (i);
                actor.set_translation (0.0f, 0.0f, 0.0f);

                unowned Meta.WindowActor? window = actor as Meta.WindowActor;
                if (window == null) {
                    clutter_actor_reparent (actor, parents.nth_data (i));
                    continue;
                }

                unowned Meta.Window? meta_window = window.get_meta_window ();
                if (!window.is_destroyed ()) {
                    if (meta_window != null
                        && meta_window.get_window_type () == Meta.WindowType.NOTIFICATION) {
                        reparent_notification_window (actor, parents.nth_data (i));
                    } else {
                        clutter_actor_reparent (actor, parents.nth_data (i));
                    }
                }

                kill_window_effects (window);

                if (meta_window != null
                    && meta_window.get_workspace () != active_workspace
                    && !meta_window.is_on_all_workspaces ())
                    window.hide ();

                // some static windows may have been faded out
                if (actor.opacity < 255U) {
                    actor.save_easing_state ();
                    actor.set_easing_duration (300);
                    actor.opacity = 255U;
                    actor.restore_easing_state ();
                }
            }

            if (tmp_actors != null) {
                foreach (var actor in tmp_actors) {
                    actor.destroy ();
                }
                tmp_actors = null;
            }

            windows = null;
            parents = null;
            moving = null;

            switch_workspace_completed ();
        }

        public override void kill_switch_workspace () {
            end_switch_workspace ();
        }

        public override void locate_pointer () {
            pointer_locator.show_ripple ();
        }

        public override bool keybinding_filter (Meta.KeyBinding binding) {
            if (!is_modal ())
                return false;

            var modal_proxy = modal_stack.peek_head ();
            if (modal_proxy == null) {
                return false;
            }

           unowned var filter = modal_proxy.get_keybinding_filter ();
            if (filter == null) {
                return false;
            }

            return filter (binding);
        }

        public override void confirm_display_change () {
            var dialog = new AccessDialog (
                _("Keep new display settings?"),
                _("Changes will automatically revert after 30 seconds."),
                "preferences-desktop-display"
            ) {
                accept_label = _("Keep Settings"),
                deny_label = _("Use Previous Settings")
            };

            dialog.show.connect (() => {
                Timeout.add_seconds (30, () => {
                    dialog.close ();

                    return Source.REMOVE;
                });
            });

            dialog.response.connect ((res) => {
                complete_display_change (res == 0);
            });

            dialog.show ();
        }

        public override unowned Meta.CloseDialog create_close_dialog (Meta.Window window) {
            var new_dialog = CloseDialog.open_dialogs.first_match ((d) => d.window == window);

            if (new_dialog == null) {
                new_dialog = new CloseDialog (window);
            }

            unowned var dialog = new_dialog;
            return dialog;
        }

        public override unowned Meta.PluginInfo? plugin_info () {
            return info;
        }

        private async void screenshot_current_window () {
            try {
                var date_time = new GLib.DateTime.now_local ().format ("%Y-%m-%d %H.%M.%S");
                /// TRANSLATORS: %s represents a timestamp here
                string file_name = _("Screenshot from %s").printf (date_time);
                bool success = false;
                string filename_used = "";
                var screenshot_manager = ScreenshotManager.init (this);
                yield screenshot_manager.screenshot_window (true, false, true, file_name, out success, out filename_used);
            } catch (Error e) {
                // Ignore this error
            }
        }

        /**
         * Notification windows are a special case where the transition state needs
         * to be preserved when reparenting the actor. Because Clutter doesn't allow specifying
         * remove_child flags we will save the elapsed time of required transitions and
         * then advance back to it when we're done reparenting.
         */
        static void reparent_notification_window (Clutter.Actor actor, Clutter.Actor new_parent) {
            unowned Clutter.Transition? entry_transition = actor.get_transition (NotificationStack.TRANSITION_ENTRY_NAME);
            unowned Clutter.Transition? position_transition = actor.get_data<Clutter.Transition?> (NotificationStack.TRANSITION_MOVE_STACK_ID);

            uint elapsed_entry = 0U, elapsed_position = 0U;

            bool save_entry = entry_transition != null && entry_transition.is_playing ();
            if (save_entry) {
                elapsed_entry = entry_transition.get_elapsed_time ();
            }

            bool save_position = position_transition != null && position_transition.is_playing ();
            if (save_position) {
                elapsed_position = position_transition.get_elapsed_time ();
            }

            clutter_actor_reparent (actor, new_parent);

            if (save_entry) {
                entry_transition.advance (elapsed_entry);
                entry_transition.start ();
            }

            if (save_position) {
                position_transition.advance (elapsed_position);
                position_transition.start ();
            }
        }

        static void clutter_actor_reparent (Clutter.Actor actor, Clutter.Actor new_parent) {
            if (actor == new_parent)
                return;

            actor.ref ();
            actor.get_parent ().remove_child (actor);
            new_parent.add_child (actor);
            actor.unref ();
        }
    }

    [CCode (cname="clutter_x11_get_stage_window")]
    public extern X.Window x_get_stage_window (Clutter.Actor stage);
}
