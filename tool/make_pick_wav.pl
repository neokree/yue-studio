# Prints a 4 s silent 48 kHz stereo 16-bit wav to stdout (input for the e2e Cover step).
binmode STDOUT;
$n = 48000 * 4 * 4;
print "RIFF", pack("V", 36 + $n), "WAVEfmt ", pack("VvvVVvv", 16, 1, 2, 48000, 192000, 4, 16), "data", pack("V", $n), "\0" x $n;
