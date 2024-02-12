## Oracle instance scripts

These scripts are provider so you can easily deploy Oracle on an Azure VM and then create database using Lightbits volumes.

**Note:** make sure to set the proper the SSH Key, path to PSSH, PSCP and JQ, and the Lighbits JWT in the my_config file.

**Note:** In 3.oracle_user_setup, make sure to change the path to your ORACLE_BASE and ORACLE_HOME if they are not the path that Oracle recommends.

**Note:** In 6.copy_oracle_home, make sure to change the ORACLE_HOME_ZIP variable to the correct path file of your oracle zip download.

**Note:** This code was tested on Red Hat RHEL 8.9 with kernel 4.18.0-513.11.1.el8_9.x86_64, if you use different kernel version, make sure to get the matching kmod-redhat-oracleasm packages installed.
