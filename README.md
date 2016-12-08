# Alarms_management
CA UIM Alarms management probe.

Created with perluim framework, find it [Here](https://github.com/fraxken/perluim)

This probe has been created to manage and handle all alarms clear that the UIM product does'nt support. Few exemples : 

- Clear of death alarms after 'X' seconds (logmon,cdm, etc..) 
- Clear of inactive robots alarms
- Clear of probe_down alarms
- Clear of alarms with hostname configured as IP.

> Feel free to pull-request generic needs.

This probe is used (and customised) to support a lot of alarms case ( you have just to add all case you need ).

# Configuration

Dont use login and password from setup section if you use this script as probe in IM. 

> Dont forget to put good user and password for UMP Servers (with a user that have the right to do actions on the REST API). The delimiter for servers is ','
