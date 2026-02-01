#!/usr/bin/env python3
"""
This script sends a command to the EECS 472 autograder server which
will download your submission from your main branch on github.

The autograder will reply to your UofM email with the status of some
basic sanity checks.

Ask an instructor to get help debugging any autograder errors.
"""

from email.message import EmailMessage
from smtplib import SMTP
from time import sleep  # add delays to some printing for aesthetics
import argparse
import getpass
import sys
import os   

parser = argparse.ArgumentParser(
    description=__doc__,  # __doc__ is the docstring above
    formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument(
    '-y', '--yes', 
    action='store_true', 
    help="Assume yes, you have pushed your main branch to github")
parser.add_argument(
    '-s', '--sim', 
    action='store_true', 
    help="Submit simulation only")
args = parser.parse_args()


# Make sure you've pushed your main branch to github

if not args.yes:
    os.system("git status")
    print("Have you pushed your main branch to github?")
    sleep(0.75)  # just makes the printing look slightly nicer
    try:  # try/except to gracefully quit from Ctrl+C
        yes = input("Enter 'y' or 'yes' to continue: ")
        if yes not in ['y', 'yes', 'Y', 'Yes']:
            print("Exiting")
            sys.exit(1)
    except KeyboardInterrupt:
        print("\nExiting")
        sys.exit(1)
    print("(use -y or --yes to skip this)")

# Send command to autograder:

project_name = 'pfinal'

ag_command = f"grade 472 project {project_name}{'_sim' if args.sim else ''}"
uniqname = getpass.getuser()
host = 'eecs470.eecs.umich.edu'

msg = EmailMessage()
msg['From'] = uniqname + '@umich.edu'
msg['To'] = 'g470@' + host
msg['Subject'] = ag_command

print("Sending submission email...")

with SMTP(host) as server:
    server.send_message(msg)

sleep(0.75)  # just makes the printing look slightly nicer
print("The autograder will download your main branch from GitHub")
print("An email response with public output will be sent soon")
