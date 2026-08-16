Make a backup before you run script

You just need:

Save script into txt, for example, with name `amnesic.sh` in `/home/user/` in appVM.
Copy file to dom0. Run it in dom0 terminal (qube-name - appVM with script):
`qvm-run --pass-io qube-name 'cat /home/user/amnesic.sh' > amnesic.sh`
Make file executable. Run in dom0 terminal:
`sudo chmod +x amnesic.sh`
Run script in dom0 terminal with sudo
`sudo ./amnesic.sh`
