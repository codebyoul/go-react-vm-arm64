Read the spec file in the current folder and build the application it describes, from scratch.

- Put all your code in your own folder: `runs/<TERMINAL>__<MODEL>/` (lowercase, no spaces). Never touch anything outside it, especially other folders in `runs/`.
- Find the VirtualBox VM and deploy the app to it over SSH, exactly as the spec says. Copy your folder's `backend/` and `frontend/` to `~/app` on the VM with rsync, then run `~/app/deploy.sh`.
- Make sure it actually runs and is displayed: run the spec's verification steps, check `http://localhost:<port>` from the Mac, and fix anything that fails until it works.
- When done, give the final report and the URL.

Start now.
