cd /opt
apt install git -y
rm -rf proxmox-scripts
git clone https://github.com/mrpink77it/proxmox-scripts.git
cd proxmox-scripts
chmod +x setup-host-backups/*.sh
chmod +x *.sh
chmod +x proxmox-backup-toggle/*.sh
chmod +x lxc-sync/*.sh
clear
ls -lia
