## Hi there 👋

Version 2.0.0

This package is code for monitoring the rsync process in RsyncUI.

The package is used in [RsyncUI](https://github.com/rsyncOSX/RsyncUI).

By Using Swift Package Manager (SPM), parts of the source code in RsyncUI is extraced and created as packages. The old code, the base for packages, is deleted and RsyncUI imports the new packages.  In Xcode 26 and later there is also module for test, Swift Testing, for testing packages. By SPM and Swift Testing, the code is modularized, isolated, and tested before committing changes.