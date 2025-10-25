# check-acs-images.sh

A Bash tool to audit KVM image directories against Apache CloudStack’s MySQL database.
Detects missing, orphaned, or unregistered images, snapshot inconsistencies, and flattening candidates.

## Quick Start
```bash
git clone https://github.com/haltondc/check-acs-images
cd check-acs-images
chmod +x check-acs-images.sh
./check-acs-images.sh /var/lib/libvirt/images
