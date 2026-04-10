#!/usr/bin/perl
# log
#
# Log data to stdout and a rotating daily log file

use POSIX qw(strftime);

my $LOG_FH;
my $LOG_DATE = "";

sub log_open {
    my $date = strftime("%Y-%m-%d", localtime());
    return if $LOG_DATE eq $date && defined $LOG_FH;

    # Close previous handle if open (date rolled over)
    if (defined $LOG_FH) {
        close $LOG_FH;
        undef $LOG_FH;
    }

    my $filename = "./logs/ctf-$date.log";
    mkdir "./logs" unless -d "./logs";
    open($LOG_FH, '>>', $filename) or warn "ERROR -> Cannot open log file $filename: $!\n";
    if ($LOG_FH) {
        $LOG_FH->autoflush(1);
        $LOG_DATE = $date;
    }
}

sub do_log #($data)
{
   my $data = $_[0];
   my $line = "[" . scalar localtime() . "] " . $data . "\n";
   print STDOUT $line;
   log_open();
   print $LOG_FH $line if defined $LOG_FH;
}

return true;
