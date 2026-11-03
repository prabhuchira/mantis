import Foundation

/// Color defaults for the child shell (`shell-colors = true`).
///
/// Mantis's palette only shows up when programs emit SGR codes, and on a stock
/// macOS setup almost nothing does: BSD `ls` stays plain unless `CLICOLOR` is set,
/// and the default zsh prompt (`%n@%m %1~ %# `) has no color. This fills those gaps
/// without overriding anything the user configured themselves:
///   • `CLICOLOR` / `LSCOLORS` / `LS_COLORS` are only set when absent.
///   • zsh: a tiny ZDOTDIR shim restores the user's ZDOTDIR, sources
///     their `.zshenv`, and on the first prompt recolors PROMPT *only* if it is still
///     a stock default. Custom prompts (oh-my-zsh, starship, p10k…) are left alone.
enum ShellColors {
    /// BSD ls: dir=bold blue, symlink=bold cyan, socket=bold magenta, pipe=bold yellow,
    /// exec=bold green; remaining slots keep macOS defaults.
    static let lscolors = "ExGxFxDxCxegedabagacad"
    /// GNU ls (coreutils via Homebrew) equivalent.
    static let lsColorsGNU = "di=1;34:ln=1;36:so=1;35:pi=1;33:ex=1;32:bd=34;46:cd=34;43:su=30;41:sg=30;46:tw=30;42:ow=30;43"

    static func apply(to env: inout [String: String], shell: String) {
        if env["CLICOLOR"] == nil { env["CLICOLOR"] = "1" }
        if env["LSCOLORS"] == nil { env["LSCOLORS"] = lscolors }
        if env["LS_COLORS"] == nil { env["LS_COLORS"] = lsColorsGNU }

        guard (shell as NSString).lastPathComponent == "zsh", let dir = installZshShim() else { return }
        if let userZDOTDIR = env["ZDOTDIR"] { env["MANTIS_USER_ZDOTDIR"] = userZDOTDIR }
        env["ZDOTDIR"] = dir
    }

    static let zshenv = #"""
    # Mantis zsh shim — generated; edits are overwritten.
    # Restore the user's ZDOTDIR so zsh reads their .zprofile/.zshrc as usual.
    if [[ -n "${MANTIS_USER_ZDOTDIR-}" ]]; then
      ZDOTDIR="$MANTIS_USER_ZDOTDIR"
    else
      unset ZDOTDIR
    fi
    unset MANTIS_USER_ZDOTDIR
    [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"

    # On the first prompt, color the prompt only if it is still a stock default.
    _mantis_color_prompt() {
      precmd_functions=(${precmd_functions:#_mantis_color_prompt})
      unfunction _mantis_color_prompt
      case "$PROMPT" in
        '%n@%m %1~ %# '|'%m%# '|'%m%#'|'')
          PROMPT='%F{green}%n@%m%f %B%F{blue}%1~%b%f %(?.%F{magenta}.%F{red})%#%f '
          ;;
      esac
    }
    [[ -o interactive ]] && precmd_functions+=(_mantis_color_prompt)
    """#

    /// Writes the shim to Application Support; returns its directory (nil on failure).
    private static func installZshShim() -> String? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Mantis/shell-integration/zsh", isDirectory: true)
        let file = dir.appendingPathComponent(".zshenv")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != zshenv {
                try zshenv.write(to: file, atomically: true, encoding: .utf8)
            }
            return dir.path
        } catch {
            return nil
        }
    }
}
