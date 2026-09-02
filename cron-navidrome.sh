# Script per spostare file da una cartella dell'host proxmox a una dentro un container LXC

CTID="100" # Inserisci il numero del tuo container di destinazione
SRC_DIR="/srv/temp/music"
DEST_DIR="/opt/navidrome/music"

# Enable globbing to include hidden files if any, and handle empty directory safely
shopt -s dotglob nullglob

# Check if source directory exists and contains files/folders
files=("$SRC_DIR"/*)
if [ ! -d "$SRC_DIR" ] || [ ${#files[@]} -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Source directory empty or missing. Operations skipped."
    exit 0
fi

# Ensure destination directory exists inside LXC container
pct exec "$CTID" -- mkdir -p "$DEST_DIR"

ERRORS=0

# Loop through all files and subdirectories in SRC_DIR
for item in "$SRC_DIR"/*; do
    [ -e "$item" ] || continue
    
    filename=$(basename "$item")
    dest_path="$DEST_DIR/$filename"
    
    # Push item to container
    if pct push "$CTID" "$item" "$dest_path"; then
        # Delete only if push was successful
        rm -rf "$item"
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR pushing: $filename" >&2
        ERRORS=$((ERRORS + 1))
    fi
done

if [ $ERRORS -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync and cleanup completed successfully."
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Completed with $ERRORS error(s)." >&2
    exit 1
fi
