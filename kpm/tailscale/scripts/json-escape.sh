# Print $1 as a JSON string literal, including the surrounding quotes.
# Control bytes are dropped. Backslash and double quote are escaped.
json_string() {
    _j=$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '"%s"' "$_j"
}
