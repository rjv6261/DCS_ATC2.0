# DCS_ATC 2.0

If you look at the attached file, that is my current work for .lua . There is more going on and I am simply including the main file so that others can see progress on it as we go. I have a solid idea of what I want to improve and add to DCS.

RIGHT NOW THE SCRIPT IS BEING TESTED! IF IT WORKS, I WILL BEGIN TO IMPLEMENT MORE LOGIC FOR START-UP and TAXI/TAKEOFF

A mod/script for the popular game DCS. This will hopefully work to slowly improve and upgrade their ATC system. As of right now, I am still working on it and trying to get it implemented, bear with me and if you feel that you can help, add me on discord @spicy2160

Plans right now are rough but are below (attached to this repo is the .lua I am building on)

Update Alpha 1.0
- F10 menu: ATC > [Ground Control, Tower, Approach] submenus.
- Ground: Request Startup (with wingmen check), Request Taxi (placeholder path).
- Tower: Request Takeoff (placeholder clearance).
- Approach: Inbound VFR/IFR (placeholder response).
- Frequency advice: Checks player's radio vs. nearest airbase, displays "Switch to X MHz" if mismatched.
- System messages: All ATC interactions shown in top-right (10s duration, stackable).
- Event-driven: Responds to player entering unit, radio messages, and takeoffs.

Update Alpha 1.1
- Different menus that are similar to BMS, allowing the user to dictate Start-up, Taxi, Takeoff, Landing , parking (or maybe I will dictate it based on state)
