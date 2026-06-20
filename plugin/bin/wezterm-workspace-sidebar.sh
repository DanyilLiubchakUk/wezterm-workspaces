#!/bin/zsh

set -u

active_name="${1:-}"
data_file="${2:-$HOME/.config/wezterm/workspace_sidebar.tsv}"
configured_height="${3:-}"
configured_width="${4:-}"
help_state_file="${HOME}/.config/wezterm/workspace_sidebar_help_state.txt"

typeset -ga indexes keys names labels titles descs paths notes previews active_flags
typeset -gA row_to_index
scroll_offset=0
selected_index=0
redraw_pending=0

reset=$'\033[0m'
bold=$'\033[1m'
enter_alt=$'\033[?1049h'
exit_alt=$'\033[?1049l'
sync_start=$'\033[?2026h'
sync_end=$'\033[?2026l'
hide_cursor=$'\033[?25l'
show_cursor=$'\033[?25h'
mouse_on=$'\033[?1000h\033[?1006h'
mouse_off=$'\033[?1000l\033[?1006l'
bg_panel=$'\033[48;2;13;15;19m'
bg_panel_soft=$'\033[48;2;16;18;23m'
bg_active=$'\033[48;2;0;156;255m'
bg_active_soft=$'\033[48;2;0;118;235m'
fg_title=$'\033[38;2;236;239;244m'
fg_text=$'\033[38;2;203;213;225m'
fg_muted=$'\033[38;2;137;148;164m'
fg_dim=$'\033[38;2;89;97;112m'
fg_accent=$'\033[38;2;125;211;252m'
fg_active=$'\033[38;2;255;255;255m'
fg_active_subtle=$'\033[38;2;219;234;254m'
fg_key=$'\033[38;2;229;231;235m'

saved_tty_state="$(stty -g 2>/dev/null || true)"

cleanup() {
  if [[ -n "${saved_tty_state:-}" ]]; then
    stty "$saved_tty_state" 2>/dev/null || true
  fi
  printf "%s%s%s%s" "$reset" "$show_cursor" "$mouse_off" "$exit_alt"
}

if [[ -n "$saved_tty_state" ]]; then
  stty -echo -echoctl 2>/dev/null || stty -echo 2>/dev/null || true
fi

trap cleanup EXIT

TRAPWINCH() {
  redraw_pending=1
}

positive_int() {
  local value="$1"
  local fallback="${2:-1}"

  if [[ "$value" != <-> ]]; then
    value="$fallback"
  fi
  if [[ "$value" != <-> ]]; then
    value=1
  fi
  if (( value < 1 )); then
    value=1
  fi

  print -- "$value"
}

emit_user_var() {
  local name="$1"
  local raw="${2:-1}"
  local value
  value=$(printf '%s' "$raw" | base64 | tr -d '\n')
  printf '\033]1337;SetUserVar=%s=%s\007' "$name" "$value"
}

emit_workspace() {
  emit_user_var "wezterm_workspace" "$1	$$:$RANDOM:$SECONDS"
}

emit_workspace_delete() {
  emit_user_var "wezterm_workspace_delete" "$1	$$:$RANDOM:$SECONDS"
}

emit_workspace_next_or_create() {
  emit_user_var "wezterm_workspace_next_or_create" "$$:$RANDOM:$SECONDS"
}

emit_sidebar_selection() {
  if [[ -n "${names[$selected_index]:-}" ]]; then
    emit_user_var "wezterm_workspace_selected" "${names[$selected_index]}	$$:$RANDOM:$SECONDS"
  fi
}

switch_workspace() {
  local workspace="$1"
  emit_workspace "$workspace"
}

pane_width() {
  local size width
  size="$(stty size 2>/dev/null || true)"
  width="${size##* }"
  if [[ "$width" == "$size" ]]; then
    width="${COLUMNS:-${configured_width:-42}}"
  fi
  positive_int "$width" "${configured_width:-42}"
}

pane_height() {
  local size height
  size="$(stty size 2>/dev/null || true)"
  height="${size%% *}"
  if [[ "$height" == "$size" ]]; then
    height="${LINES:-${configured_height:-36}}"
  fi
  height="$(positive_int "$height" "${configured_height:-36}")"
  if (( height < 16 )); then
    height=16
  fi
  print -- "$height"
}

trim_to_width() {
  local text="$1"
  local width="$2"

  width="$(positive_int "$width" 1)"

  if (( width <= 0 )); then
    text=""
  elif (( ${#text} > width )); then
    if (( width == 1 )); then
      text="."
    else
      text="${text[1,$((width - 1))]}."
    fi
  fi

  print -r -- "$text"
}

line_count=0
draw_height=0

paint_line() {
  local bg="$1"
  local fg="$2"
  local text="$3"
  local width="${4:-$(pane_width)}"
  local ending=$'\n'

  width="$(positive_int "$width" 1)"

  if (( draw_height > 0 && line_count + 1 >= draw_height )); then
    ending=""
  fi

  text="$(trim_to_width "$text" "$width")"
  printf '%b%-*s\033[K%b%s' "${bg}${fg}" "$width" "$text" "$reset" "$ending"
  (( line_count++ ))
}

gap() {
  paint_line "$bg_panel" "$fg_dim" ""
}

fill_canvas() {
  local width="$1"
  local height="$2"
  local row ending

  width="$(positive_int "$width" 1)"
  height="$(positive_int "$height" 1)"

  printf '\033[H'
  for (( row = 1; row <= height; row++ )); do
    ending=$'\n'
    if (( row == height )); then
      ending=""
    fi

    printf '%b%*s\033[K%b%s' "$bg_panel" "$width" "" "$reset" "$ending"
  done
  printf '\033[H'
}

paint_separator() {
  local width="${1:-$(pane_width)}"
  local line
  width="$(positive_int "$width" 1)"
  printf -v line '%*s' "$width" ''
  line="${line// /─}"
  paint_line "$bg_panel" "$fg_dim" "$line" "$width"
}

paint_doc_line() {
  local text="$1"

  paint_line "$bg_panel" "$fg_muted" "  $text"
}

paint_doc_pair() {
  local key="$1"
  local label="$2"
  local width="${3:-$(pane_width)}"

  width="$(positive_int "$width" 1)"

  if (( width < 10 )); then
    paint_doc_line "$key"
  else
    paint_doc_line "$key $label"
  fi
}

help_visible() {
  local state
  state="$(cat "$help_state_file" 2>/dev/null || true)"
  [[ "$state" != "hidden" ]]
}

toggle_help() {
  if help_visible; then
    print -r -- "hidden" > "$help_state_file" 2>/dev/null || true
  else
    print -r -- "open" > "$help_state_file" 2>/dev/null || true
  fi
  draw
}

fallback_data() {
  indexes=()
  keys=()
  names=()
  labels=()
  titles=()
  descs=()
  paths=()
  notes=()
  previews=()
  active_flags=()
}

data_mtime() {
  local workspace_mtime help_mtime
  workspace_mtime="$(stat -f "%m:%z" "$data_file" 2>/dev/null || print -- "0:0")"
  help_mtime="$(stat -f "%m:%z" "$help_state_file" 2>/dev/null || print -- "0:0")"
  print -- "${workspace_mtime}:${help_mtime}"
}

load_workspaces() {
  indexes=()
  keys=()
  names=()
  labels=()
  titles=()
  descs=()
  paths=()
  notes=()
  previews=()
  active_flags=()

  if [[ -r "$data_file" ]]; then
    local index key name label title desc live_line note preview active
    while IFS='|' read -r index key name label title desc live_line note preview active; do
      [[ -z "${name:-}" ]] && continue
      indexes+=("${index:-${#names}}")
      keys+=("${key:-}")
      names+=("$name")
      labels+=("${label:-$name}")
      titles+=("${title:-$label}")
      descs+=("${desc:-workspace}")
      paths+=("${live_line:-}")
      notes+=("${note:-custom workspace}")
      previews+=("${preview:-}")
      active_flags+=("${active:-0}")

      if [[ "${active:-0}" == "1" ]]; then
        active_name="$name"
      fi
    done < "$data_file"
  fi

  if (( ${#names[@]} == 0 )); then
    fallback_data
  fi
}

active_index() {
  if (( ${#names[@]} == 0 )); then
    print -- "0"
    return
  fi

  local i
  for (( i = 1; i <= ${#names[@]}; i++ )); do
    if [[ "$names[$i]" == "$active_name" ]]; then
      print -- "$i"
      return
    fi
  done
  print -- "1"
}

ensure_active_visible() {
  local active_i="$1"
  local list_height="$2"

  if (( active_i < 1 )); then
    scroll_offset=0
    return
  fi

  if (( active_i <= scroll_offset )); then
    scroll_offset=$((active_i - 1))
  elif (( active_i > scroll_offset + list_height )); then
    scroll_offset=$((active_i - list_height))
  fi

  if (( scroll_offset < 0 )); then
    scroll_offset=0
  fi
}

ensure_selected_index() {
  local fallback="$1"

  if (( ${#names[@]} == 0 )); then
    selected_index=0
    return
  fi

  if (( fallback < 1 )); then
    fallback=1
  fi

  if (( selected_index < 1 || selected_index > ${#names[@]} )); then
    selected_index="$fallback"
  fi
}

draw_header() {
  local i="$1"
  local width
  width="$(pane_width)"
  width="$(positive_int "$width" 1)"

  paint_line "$bg_panel" "$fg_dim" "  WORKSPACES"

  if ! help_visible; then
    paint_doc_pair "⌥+/" "show shortcuts" "$width"
  elif (( width < 24 )); then
    paint_doc_pair "⌥+/" "shortcuts" "$width"
    paint_doc_pair "↵" "open" "$width"
    paint_doc_pair "⇅" "select" "$width"
  elif (( width < 42 )); then
    paint_doc_line "[1-9]/↵ open"
    paint_doc_line "⌥+N next/new  ⌥+⌫ delete"
    paint_doc_line "⇅ select  ⌘+⇅ move"
    paint_doc_line "⌥+/ hide shortcuts"
  else
    paint_doc_line "[1-9]/↵ open    ⌥+N next/new    ⌥+⌫ delete"
    paint_doc_line "⇅ select       ⌘+⌥+[1-9] workspace"
    paint_doc_line "⌘+⇅ workspaces ⌘+⇄ tabs"
    paint_doc_line "⌘+B panel       ⌘+D top names"
    paint_doc_line "⌘+W close tab   ⌥+/ hide shortcuts"
  fi

  paint_separator "$width"

  if (( ${#names[@]} == 0 || i < 1 )); then
    paint_line "$bg_panel" "${fg_title}${bold}" "  No workspaces yet"
    paint_line "$bg_panel" "$fg_muted" "  Press ⌘+↓ or ⌥+N to add your first one"
    gap
    return
  fi
}

draw_group() {
  local i="$1"
  local marker=" "
  local bg="$bg_panel"
  local fg_main="$fg_text"
  local fg_sub="$fg_muted"
  local fg_path="$fg_dim"
  local number="${indexes[$i]}"
  local start_line=$((line_count + 1))
  local width
  width="$(pane_width)"
  width="$(positive_int "$width" 1)"

  if [[ "$names[$i]" == "$active_name" ]]; then
    marker=">"
    bg="$bg_active"
    fg_main="${fg_active}${bold}"
    fg_sub="$fg_active_subtle"
    fg_path="$fg_active_subtle"
  elif (( i == selected_index )); then
    marker="*"
    bg="$bg_panel_soft"
    fg_main="${fg_accent}${bold}"
    fg_sub="$fg_text"
    fg_path="$fg_muted"
  fi

  if (( width < 14 )); then
    paint_line "$bg" "$fg_main" "${marker}${number} ${titles[$i]}"
  else
    paint_line "$bg" "$fg_main" " ${marker} ${number}  ${titles[$i]}"
    paint_line "$bg" "$fg_sub" "      ${notes[$i]}"
  fi

  if (( width >= 14 )) && [[ -n "${previews[$i]:-}" ]]; then
    paint_line "$bg" "$fg_sub" "      ${previews[$i]}"
  fi

  if (( width >= 14 )) && [[ -n "${paths[$i]:-}" ]]; then
    if [[ "$names[$i]" == "$active_name" ]]; then
      paint_line "$bg_active_soft" "$fg_path" "      ${paths[$i]}"
    else
      paint_line "$bg" "$fg_path" "      ${paths[$i]}"
    fi
  fi

  if [[ "$names[$i]" == "$active_name" ]]; then
    gap
  else
    paint_line "$bg_panel_soft" "$fg_dim" ""
  fi

  local row
  for (( row = start_line - 1; row <= line_count; row++ )); do
    (( row < 1 )) && continue
    row_to_index[$row]="$i"
  done
}

draw() {
  redraw_pending=0
  load_workspaces
  row_to_index=()

  local height
  height="$(pane_height)"
  local width
  width="$(pane_width)"
  height="$(positive_int "$height" 16)"
  width="$(positive_int "$width" 1)"
  local active_i
  active_i="$(active_index)"
  ensure_selected_index "$active_i"

  printf '%s%s' "$hide_cursor" "$mouse_on"
  printf '\033]0;workspace-sidebar\007\033]2;workspace-sidebar\007'
  printf '%b\033[H\033[2J%b' "$bg_panel" "$reset"

  line_count=0
  draw_height="$height"
  fill_canvas "$width" "$height"
  draw_header "$active_i"

  local list_height=$((height - line_count))
  if (( list_height < 4 )); then
    list_height=4
  fi

  ensure_active_visible "$selected_index" "$list_height"

  local i=$((scroll_offset + 1))
  while (( i <= ${#names[@]} && line_count + 4 <= height )); do
    draw_group "$i"
    (( i++ ))
  done

  while (( line_count < height )); do
    gap
  done

  printf '\033[H%s' "$reset"
  last_data_mtime="$(data_mtime)"
  emit_sidebar_selection
}

move_selection() {
  local delta="$1"
  load_workspaces
  ensure_selected_index "$(active_index)"

  if (( ${#names[@]} == 0 )); then
    draw
    return
  fi

  selected_index=$((selected_index + delta))
  if (( selected_index < 1 )); then
    selected_index=1
  elif (( selected_index > ${#names[@]} )); then
    selected_index="${#names[@]}"
  fi

  draw
}

activate_selected() {
  load_workspaces
  ensure_selected_index "$(active_index)"

  if [[ -n "${names[$selected_index]:-}" ]]; then
    active_name="$names[$selected_index]"
    switch_workspace "$active_name" "$selected_index"
  fi
}

delete_selected() {
  load_workspaces
  ensure_selected_index "$(active_index)"

  if [[ -n "${names[$selected_index]:-}" ]]; then
    local target="$names[$selected_index]"
    emit_workspace_delete "$target"
  fi
}

read_escape_sequence() {
  local seq=$'\033'
  local ch

  IFS= read -rs -k 1 -t 0.25 ch || {
    print -rn -- "$seq"
    return
  }

  seq+="$ch"

  if [[ "$ch" == "[" ]]; then
    while IFS= read -rs -k 1 -t 0.25 ch; do
      seq+="$ch"
      if [[ "$ch" == "~" || "$ch" == "M" || "$ch" == "m" || "$ch" == [ABCD] ]]; then
        break
      fi
      (( ${#seq} > 40 )) && break
    done
  elif [[ "$ch" == "O" ]]; then
    IFS= read -rs -k 1 -t 0.25 ch && seq+="$ch"
  fi

  print -rn -- "$seq"
}

maybe_redraw_if_data_changed() {
  local current_mtime
  current_mtime="$(data_mtime)"

  if [[ "$current_mtime" != "${last_data_mtime:-}" ]]; then
    draw
  fi
}

maybe_redraw() {
  if (( redraw_pending )); then
    draw
    return
  fi

  maybe_redraw_if_data_changed
}

handle_mouse() {
  local seq="$1"
  [[ "$seq" == $'\033[<'* ]] || return 1

  local payload="${seq#$'\033[<'}"
  local suffix="${payload[-1]}"
  [[ "$suffix" == "M" ]] || return 1

  payload="${payload[1,-2]}"
  local -a parts
  parts=("${(@s:;:)payload}")

  local button="${parts[1]:-}"
  local row="${parts[3]:-}"
  [[ "$button" == "0" && -n "$row" ]] || return 1

  local idx="${row_to_index[$row]:-}"
  if [[ -n "$idx" && -n "${names[$idx]:-}" ]]; then
    selected_index="$idx"
    activate_selected
    return 0
  fi

  return 1
}

printf '%s' "$enter_alt"
draw
last_data_mtime="$(data_mtime)"

if [[ ! -t 0 ]]; then
  exit 0
fi

while true; do
  if ! IFS= read -rs -k 1 -t 0.25 key; then
    maybe_redraw
    continue
  fi

  if [[ "$key" == $'\033' ]]; then
    key="$(read_escape_sequence)"
  fi

  case "$key" in
    $'\033[A')
      move_selection -1
      ;;
    $'\033[B')
      move_selection 1
      ;;
    $'\033[<'*)
      handle_mouse "$key" || true
      ;;
    $'\r'|$'\n'|" ")
      activate_selected
      ;;
    $'\033\177'|$'\033\b'|$'\033[3~')
      delete_selected
      ;;
    n|N|$'\033n'|$'\033N')
      emit_workspace_next_or_create
      ;;
    r|R)
      emit_user_var "wezterm_workspace_rename" "$active_name	$$:$RANDOM:$SECONDS"
      ;;
    s|S)
      emit_user_var "wezterm_workspace_switcher" "$$:$RANDOM:$SECONDS"
      ;;
    $'\033/')
      toggle_help
      ;;
    j)
      (( scroll_offset++ ))
      draw
      ;;
    k)
      (( scroll_offset-- ))
      if (( scroll_offset < 0 )); then
        scroll_offset=0
      fi
      draw
      ;;
    [1-9])
      idx="$key"
      if (( idx <= ${#names[@]} )); then
        selected_index="$idx"
        active_name="$names[$idx]"
        switch_workspace "$names[$idx]" "$idx"
      fi
      ;;
  esac
done
