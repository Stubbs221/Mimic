// Created by Василий Маслов on 06.10.2026.
import Foundation

/// App-only transport names; permissions and checkout identity are verified again by the native owner.
public enum PanelBridge {
    /// Agent workflows use the same reviewed preview and digest checks as the private panel.
    public static let generatorTools = ["preview_generator", "get_generator_preview", "generate_files"]
    public static let appTools = ["panel_run_tool", "panel_save_tools_preferences", "panel_get_tool_configuration", "panel_get_ci_details", "panel_get_workspace", "panel_save_workspace", "panel_save_layout", "panel_setup", "panel_branches", "panel_switch_branch", "panel_preview_generator", "panel_get_preview", "panel_generate", "panel_terminal_open", "panel_terminal_poll", "panel_terminal_send", "panel_terminal_close", "panel_secret_input", "panel_bootstrap_control"]
}
