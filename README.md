# Follow
Follow is a command line program that runs user-given commands following a write to user-specified file(s).
More specifically, following the closing of a file opened with write permissions.

Follow attempts to run indefinitely; Follow does not end after a set amount of events.

Follow waits for a forked child to finish running a user's command before it continues waiting for/reading events.

# Usage:
> follow [files] [commands]

Note: Commands are sent to /bin/sh using the current environmental variables. They will be parsed however that program likes.
If you want to pass items such as && or |, don't forget to escape them first.

There is one replacement that Follow will make in the command. Follow will turn %f into the relative filepath that triggered the event. 

# Example:

> follow file1.c dir/file2.zig another-file.txt echo write event detected at %f '&&' echo command 2

User opens dir/file2.zig with write permissions, and then closes the file. Output would be:

	write event detected at dir/file2.zig

	command 2

One would achieve the same outcome in this particular scenario if the original call was
 > follow dir/ echo write event detected at %f '&&' echo command 2


# Fun Facts
Follow utilizes the inotify api to quickly react to write events.

Follow treats Vim writes (replacing a file with a buffer) as regular write events.

Follow was originally written by me in C, this is a reimplemntation and improvement in Zig.

Written for version '0.4.0+2cbcf3f3' of Zig.
