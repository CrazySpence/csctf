#!/usr/bin/perl
#CrazySpence CTF Server side
#This will log player captures, drops, pk's in an attempt to sanity check the game. Hopefully people would rather have fun than exploit the game but give history I doubt it

use strict;
use Event;
use Socket;
use IO::Select;
use IO::Socket::INET;
use warnings;
use IPC::Open3;
use DBD::mysql;
use Storable qw(store retrieve);
use File::Copy;

# uncomment to handle SIGPIPE yourself
$SIG{PIPE} = sub { warn "ERROR -> Broken pipe detected\n" };

require "./log.pl";

our %OPTIONS;
require "./options.pl";

my $SOCKET; #Main Socket
my $SELECT;
my $MINUTE; #minute timer
my @CPOOL;  #Connection pool hashes
my $SQL; #Database connection handler
my $BACKUP_COUNTER = 0;
my %PENDING_VERIFY; # "$handle" => Event timer (waiting for VERSION response)
my %RECENT_KILLS;   # "victim:killer" => timestamp, used to deduplicate ACTION 2 reports

my %CTFSTATE = (
	TeamOnePlayers    => 0,
	TeamTwoPlayers    => 0,
	TeamOneCarrier    => "",
	TeamTwoCarrier    => "",
	TeamOneScore      => 0,
	TeamTwoScore      => 0,
	TeamOneStation    => "Sedina D-14",
	TeamTwoStation    => "Bractus D-9",
    TeamOneFlagSector => "",
	TeamTwoFlagSector => "",
	TeamOneFlagItem   => "",
	TeamTwoFlagItem   => "",
	TeamOneTimeout      => 0,
	TeamTwoTimeout      => 0,
	BountyTable         => {},
	TeamOneCarryHistory => [],
	TeamTwoCarryHistory => [],
	PendingChallenge    => {},
);

sub state_save {
    my %save;
    # Persist everything except live player counts — those reset as clients reconnect
    for my $key (keys %CTFSTATE) {
        next if $key eq 'TeamOnePlayers' || $key eq 'TeamTwoPlayers' || $key eq 'PendingChallenge';
        $save{$key} = $CTFSTATE{$key};
    }
    store(\%save, $OPTIONS{STATE_FILE})
        or do_log(sprintf("ERROR -> Failed to save game state: %s", $!));
    if ($OPTIONS{DEBUG}) { do_log("STATE -> Game state saved") }
}

sub state_load {
    if (-f $OPTIONS{STATE_FILE}) {
        my $saved = eval { retrieve($OPTIONS{STATE_FILE}) };
        if ($saved) {
            for my $key (keys %$saved) {
                $CTFSTATE{$key} = $$saved{$key};
            }
            $CTFSTATE{TeamOnePlayers} = 0;
            $CTFSTATE{TeamTwoPlayers} = 0;
            do_log("STATE -> Game state restored from previous session");
            do_log(sprintf("STATE -> Score: Team 1: %d  Team 2: %d",
                $CTFSTATE{TeamOneScore}, $CTFSTATE{TeamTwoScore}));
            if ($CTFSTATE{TeamOneFlagItem} ne "") {
                do_log(sprintf("STATE -> Team 1 flag (%s) was in play | carrier: %s | sector: %s",
                    $CTFSTATE{TeamOneFlagItem},
                    $CTFSTATE{TeamOneCarrier} || "none",
                    $CTFSTATE{TeamOneFlagSector}));
            }
            if ($CTFSTATE{TeamTwoFlagItem} ne "") {
                do_log(sprintf("STATE -> Team 2 flag (%s) was in play | carrier: %s | sector: %s",
                    $CTFSTATE{TeamTwoFlagItem},
                    $CTFSTATE{TeamTwoCarrier} || "none",
                    $CTFSTATE{TeamTwoFlagSector}));
            }
            # If either flag had a carrier, give them 60 seconds to reconnect and verify
            if ($CTFSTATE{TeamOneCarrier} ne "" || $CTFSTATE{TeamTwoCarrier} ne "") {
                do_log("STATE -> Flag carriers were active at shutdown, waiting 60s for reconnect...");
                Event->timer(at => time + 60, cb => \&carrier_reconnect_timeout);
            }
        } else {
            do_log(sprintf("ERROR -> Failed to read state file: %s", $@));
        }
    } else {
        do_log("STATE -> No saved state found, starting fresh");
    }
}

sub version_ge {
    # Returns 1 if $v1 >= $v2 (dot-separated version strings)
    my ($v1, $v2) = @_;
    my @a = split(/\./, $v1 // "0");
    my @b = split(/\./, $v2 // "0");
    for my $i (0..2) {
        my $a = $a[$i] // 0;
        my $b = $b[$i] // 0;
        return 1 if $a > $b;
        return 0 if $a < $b;
    }
    return 1;
}

sub db_migrate {
    return unless $SQL;
    for my $col (qw(captures assists pks total_score)) {
        $SQL->do("ALTER TABLE player_stat ADD COLUMN IF NOT EXISTS $col INT NOT NULL DEFAULT 0");
    }
    if ($OPTIONS{DEBUG}) { do_log("DB -> Migration complete") }
}

sub getplayer {
    my $nickname = $_[0];
    for my $pool (@CPOOL) {
        if (lc($$pool{nickname}) eq lc($nickname)) {
            return $pool;
        }
    }
    return undef;
}

sub stat_add {
    my ($nickname, $column, $amount) = @_;
    return unless $SQL;
    db_check();
    my %allowed = map { $_ => 1 } qw(captures assists pks total_score);
    return unless $allowed{$column};
    $SQL->do("UPDATE player_stat SET $column = $column + ? WHERE name = ?", undef, $amount, $nickname);
}

sub bounty_reset {
    my $nickname = $_[0];
    my $player = getplayer($nickname);
    if ($player) {
        $$player{bounty} = 100;
    }
    $CTFSTATE{BountyTable}{$nickname} = 100;
}

sub carry_history_add {
    my ($team, $nickname) = @_;
    my $hist = $team == 1 ? $CTFSTATE{TeamOneCarryHistory} : $CTFSTATE{TeamTwoCarryHistory};
    for my $name (@$hist) {
        return if lc($name) eq lc($nickname);
    }
    push @$hist, $nickname;
}

sub carry_history_clear {
    my $team = $_[0];
    if ($team == 1) {
        $CTFSTATE{TeamOneCarryHistory} = [];
    } else {
        $CTFSTATE{TeamTwoCarryHistory} = [];
    }
}

sub get_team_score {
    my $team = $_[0];
    return 0 unless $SQL;
    db_check();
    my $row = $SQL->selectrow_arrayref("SELECT SUM(total_score) FROM player_stat WHERE team=?", undef, $team);
    return $row && defined $row->[0] ? $row->[0] : 0;
}

sub handle_score_request {
    my $source = $_[0];
    return unless $source && $SQL;
    db_check();
    my $row = $SQL->selectrow_hashref("SELECT captures, assists, pks, total_score FROM player_stat WHERE name=?", undef, $$source{nickname});
    my $captures   = $row ? $row->{captures}    : 0;
    my $assists    = $row ? $row->{assists}      : 0;
    my $total      = $row ? $row->{total_score}  : 0;
    my $bounty     = $$source{bounty} // 0;
    my $t1_total   = get_team_score(1);
    my $t2_total   = get_team_score(2);
    player_msg($source, sprintf("SCOREDATA %d %d %d %d %d %d %d %d",
        $CTFSTATE{TeamOneScore}, $CTFSTATE{TeamTwoScore},
        $total, $bounty, $captures, $assists,
        $t1_total, $t2_total));
}

sub carrier_reconnect_timeout {
    # Fires 60 seconds after startup if there were carriers in the restored state.
    # Any carrier who has not rejoined by now gets their flag reset.
    my $changed = 0;
    if ($CTFSTATE{TeamOneCarrier} ne "" && !is_registered($CTFSTATE{TeamOneCarrier})) {
        do_log(sprintf("STATE -> Carrier %s did not reconnect, resetting Team 1 flag", $CTFSTATE{TeamOneCarrier}));
        global_msg(sprintf("Flag carrier %s did not reconnect. Team 2's flag has been reset.", $CTFSTATE{TeamOneCarrier}));
        $CTFSTATE{TeamOneCarrier}    = "";
        $CTFSTATE{TeamOneFlagItem}   = "";
        $CTFSTATE{TeamOneFlagSector} = "";
        team_msg(1, "RESETFLAG");
        $changed = 1;
    }
    if ($CTFSTATE{TeamTwoCarrier} ne "" && !is_registered($CTFSTATE{TeamTwoCarrier})) {
        do_log(sprintf("STATE -> Carrier %s did not reconnect, resetting Team 2 flag", $CTFSTATE{TeamTwoCarrier}));
        global_msg(sprintf("Flag carrier %s did not reconnect. Team 1's flag has been reset.", $CTFSTATE{TeamTwoCarrier}));
        $CTFSTATE{TeamTwoCarrier}    = "";
        $CTFSTATE{TeamTwoFlagItem}   = "";
        $CTFSTATE{TeamTwoFlagSector} = "";
        team_msg(2, "RESETFLAG");
        $changed = 1;
    }
    state_save() if $changed;
}

sub main()
{
  if (!$OPTIONS{DEBUG})
  {
     fork and exit;
  } 
  do_log(sprintf('MAIN -> CTF Build %s', $OPTIONS{DD_BUILD}));
  server_init(); #Start the CTF
  state_load(); #restore state from previous session
  db_init();
  db_migrate();
  game_init(); #start timers
  while (1) 
  {
    server_cycle();
    Event::sweep();
  }
}

sub db_init {
    my $data_source;

    #Connect to database
    if ($OPTIONS{DEBUG}) { do_log("DB INIT -> Connecting to MySQL Database") }
    $data_source = sprintf('DBI:mysql:database=%s;host=%s;port=%d', $OPTIONS{DB_DB}, $OPTIONS{DB_HOST}, $OPTIONS{DB_PORT});
    $SQL = DBI->connect($data_source, $OPTIONS{DB_USER}, $OPTIONS{DB_PASS},
        { PrintError => 0, RaiseError => 0 });
}

sub db_reconnect {
    # Attempt to reconnect up to 3 times. Dies if all attempts fail.
    for my $attempt (1..3) {
        do_log(sprintf("DB -> Reconnect attempt %d of 3...", $attempt));
        $SQL->disconnect() if $SQL;
        $SQL = undef;
        db_init();
        if ($SQL && $SQL->ping()) {
            do_log("DB -> Reconnected successfully");
            return 1;
        }
        sleep(5);
    }
    do_log("DB -> Could not reconnect to MySQL after 3 attempts, shutting down");
    die "FATAL: MySQL reconnect failed after 3 attempts\n";
}

sub db_check {
    # Call before any SQL operation. Reconnects if the connection has gone away.
    return unless $SQL;
    unless ($SQL->ping()) {
        do_log("DB -> Connection lost (ping failed), reconnecting...");
        db_reconnect();
    }
}

sub game_init {
	my $time;
	
   	$time = time + (60 - (time % 60));
	$MINUTE = Event->timer(at=>$time, interval=>60,hard=>1,cb=>\&game_minute);
}

sub game_minute {
	#Ping all connected clients
  	my $pool;
  
  	foreach $pool (@CPOOL) {
     		if ( (time - $$pool{ping}) > 180 ) {
			    #no response in 3 minutes
	    		server_cleanup($$pool{handle});
     		} else {
			     player_msg($pool,"PING");
     		}	
  	}
	if($CTFSTATE{TeamOneFlagItem} ne "") {
		if($CTFSTATE{TeamOneCarrier} ne "") {
			$CTFSTATE{TeamOneTimeout} = time;
		}
		if ( (time - $CTFSTATE{TeamOneTimeout}) > 180 ) {
			global_msg("Team 2's flag has been returned");
			$CTFSTATE{TeamOneCarrier}    = "";
            $CTFSTATE{TeamOneFlagItem}   = "";
            $CTFSTATE{TeamOneFlagSector} = "";
            carry_history_clear(1);
            team_msg(1,"RESETFLAG");
            state_save();
		}
	}
	if($CTFSTATE{TeamTwoFlagItem} ne "") {
		if($CTFSTATE{TeamTwoCarrier} ne "") {
			$CTFSTATE{TeamTwoTimeout} = time;
		}
		if ( (time - $CTFSTATE{TeamTwoTimeout}) > 180 ) {
			global_msg("Team 1's flag has been returned");
			$CTFSTATE{TeamTwoCarrier}    = "";
			$CTFSTATE{TeamTwoFlagItem}   = "";
			$CTFSTATE{TeamTwoFlagSector} = "";
			carry_history_clear(2);
			team_msg(2,"RESETFLAG");
			state_save();
		}
	}

	# Prune stale recent-kills dedup entries (older than 10 seconds)
	for my $key (keys %RECENT_KILLS) {
		delete $RECENT_KILLS{$key} if (time - $RECENT_KILLS{$key}) > 10;
	}

	# Periodic backup rotation every 5 minutes
	$BACKUP_COUNTER++;
	if ($BACKUP_COUNTER >= 5) {
		$BACKUP_COUNTER = 0;
		my $base = $OPTIONS{STATE_FILE};
		File::Copy::move("$base.2", "$base.3") if -f "$base.2";
		File::Copy::move("$base.1", "$base.2") if -f "$base.1";
		File::Copy::copy($base,     "$base.1") if -f $base;
		if ($OPTIONS{DEBUG}) { do_log("STATE -> Backup rotation complete") }
	}

	#Check SQL status, reconnect if needed
	db_check();
}

sub game_action {
	my $source = $_[0];
	my $event = $_[1];
	my $message = $_[2];
	my @arguments;
	
	if ($event eq "1") {
        #Travel Log
		if ($OPTIONS{DEBUG}) { do_log(sprintf("ACTION -> %s traveled to %s",$$source{nickname},$message)) }
		$$source{sector} = $message;
		if($CTFSTATE{TeamOneCarrier} eq $$source{nickname}) {
			$CTFSTATE{TeamOneFlagSector} = $$source{sector};
		}
		if($CTFSTATE{TeamTwoCarrier} eq $$source{nickname}) {
        	$CTFSTATE{TeamTwoFlagSector} = $$source{sector};
        }
	}
	
	if ($event eq "2") {
		#PK Detected — arguments[0] is victim, arguments[1] is killer
		#PLAYER_DIED fires on all clients in sector so multiple players may report
		#the same kill — deduplicate within a 5-second window
		@arguments = split(/\:+/,$message);
		my $victim_name = $arguments[0];
		my $killer_name = $arguments[1];
		if ($OPTIONS{DEBUG}) { do_log(sprintf("ACTION -> %s killed %s", $killer_name, $victim_name)) }

		my $kill_key = "$victim_name:$killer_name";
		if (exists $RECENT_KILLS{$kill_key} && (time - $RECENT_KILLS{$kill_key}) < 5) {
			if ($OPTIONS{DEBUG}) { do_log(sprintf("ACTION -> Duplicate kill report for %s, ignoring", $kill_key)) }
		} else {
			$RECENT_KILLS{$kill_key} = time;

			# Look up victim by name — $$source may be any witness, not necessarily the victim
			my $victim = getplayer($victim_name);
			my $victim_bounty = $victim ? ($$victim{bounty} // 0)
			                           : ($CTFSTATE{BountyTable}{$victim_name} // 0);
			bounty_reset($victim_name);

			my $killer = getplayer($killer_name);
			if ($killer) {
				$$killer{bounty} = ($$killer{bounty} // 0) + 100;
				stat_add($killer_name, 'pks', 1);
				stat_add($killer_name, 'total_score', $victim_bounty) if $victim_bounty > 0;
				if ($OPTIONS{DEBUG}) { do_log(sprintf("ACTION -> %s awarded %d bounty score (victim had %d)", $killer_name, $victim_bounty, $victim_bounty)) }
			}
			state_save();
		}
	}
	
	if ($event eq "3") {
		#Flag Carrier died
        if($$source{team} == 1) {
        	if($$source{nickname} ne $CTFSTATE{TeamOneCarrier}) { return; }
            global_msg(sprintf("%s has dropped Team 2's flag(%s) in %s",$$source{nickname},$CTFSTATE{TeamOneFlagItem},$$source{sector}));
            $CTFSTATE{TeamOneCarrier} = "";
            carry_history_clear(1);
        }
        if($$source{team} == 2) {
        	if($$source{nickname} ne $CTFSTATE{TeamTwoCarrier}) { return; }
            global_msg(sprintf("%s has dropped Team 1's flag(%s) in %s",$$source{nickname},$CTFSTATE{TeamTwoFlagItem},$$source{sector}));
            $CTFSTATE{TeamTwoCarrier} = "";
            carry_history_clear(2);
        }
        state_save();
	}
	
	if ($event eq "4") {
		#Flag Created or stolen
		if ($$source{team} == 1) {
			if($CTFSTATE{TeamOneFlagItem} eq "") {
				#new flag
				if($$source{sector} ne $CTFSTATE{TeamTwoStation}) {
					do_log(sprintf("PUNK -> %s in %s tried to create flag FLAG: expected %s",$$source{nickname},$$source{sector},$CTFSTATE{TeamTwoStation}));
					player_msg($source,"RESETFLAG");
					player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
					return;
				}
				carry_history_clear(1);
			} else {
				if($CTFSTATE{TeamOneFlagItem} ne $message) {
					do_log(sprintf("PUNK -> %s tried to capture %s when %s is FLAGITEM",$$source{nickname},$message,$CTFSTATE{TeamOneFlagItem}));
					player_msg($source,"RESETFLAG");
                    player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
					return;
				}
				if($CTFSTATE{TeamOneCarrier} ne "") {
					if(lc($$source{nickname}) eq lc($CTFSTATE{TeamOneCarrier})) {
						# Same player re-picking — server missed the ACTION 5 drop, clear stale carrier
						do_log(sprintf("STATE -> Missed drop detected, clearing carrier %s and allowing re-pickup", $$source{nickname}));
						$CTFSTATE{TeamOneCarrier} = "";
					} else {
						# Different player — verify the carrier still has it before punishing
						my $carrier_src = getplayer($CTFSTATE{TeamOneCarrier});
						if($carrier_src) {
							do_log(sprintf("PUNK -> Possible flag capture attempt by %s in %s, verifying carrier hold for %s",
								$$source{nickname}, $$source{sector}, $CTFSTATE{TeamOneCarrier}));
							player_msg($carrier_src, sprintf("VERIFYCARRIER %s", $CTFSTATE{TeamOneFlagItem}));
							$CTFSTATE{PendingChallenge}{1} = {
								carrier           => $CTFSTATE{TeamOneCarrier},
								challenger        => $$source{nickname},
								challenger_sector => $$source{sector},
								flagitem          => $CTFSTATE{TeamOneFlagItem},
							};
							$CTFSTATE{PendingChallenge}{1}{timer} = Event->timer(
								at => time + 5,
								cb => sub {
									if(exists $CTFSTATE{PendingChallenge}{1}) {
										my $ch = $CTFSTATE{PendingChallenge}{1};
										do_log(sprintf("PUNK -> Carrier verify timed out for %s, denying %s",
											$ch->{carrier}, $ch->{challenger}));
										my $chal = getplayer($ch->{challenger});
										if($chal) {
											player_msg($chal, "RESETFLAG");
											player_msg($chal, sprintf("FLAGITEM %s", $ch->{flagitem}));
										}
										delete $CTFSTATE{PendingChallenge}{1};
									}
								}
							);
							return;
						} else {
							do_log(sprintf("PUNK -> %s tried to capture a flag in %s while one is already captured",
								$$source{nickname}, $$source{sector}));
							player_msg($source,"RESETFLAG");
							player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
							return;
						}
					}
				}
				if($$source{sector} ne $CTFSTATE{TeamOneFlagSector}) {
					do_log(sprintf("PUNK -> %s in %s tried to capture flag FLAG: %s",$$source{nickname},$$source{sector},$CTFSTATE{TeamOneFlagSector}));
					player_msg($source,"RESETFLAG");
                    player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
                   return;
                }
			}
			global_msg(sprintf("%s has stolen Team 2's flag!",$$source{nickname}));
			$CTFSTATE{TeamOneFlagItem}   = $message;
			$CTFSTATE{TeamOneFlagSector} = $$source{sector};
			$CTFSTATE{TeamOneCarrier}    = $$source{nickname};
			carry_history_add(1, $$source{nickname});
			team_msg(1,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
			$CTFSTATE{TeamOneTimeout} = time;
		}
		if($$source{team} == 2) {
			if($CTFSTATE{TeamTwoFlagItem} eq "") {
            	#new flag
                if($$source{sector} ne $CTFSTATE{TeamOneStation}) {
                	do_log(sprintf("PUNK -> %s in %s tried to create flag FLAG: expected %s",$$source{nickname},$$source{sector},$CTFSTATE{TeamOneStation}));
					player_msg($source,"RESETFLAG");
                    player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
                    return;
                }
                carry_history_clear(2);
            } else {
				if($CTFSTATE{TeamTwoFlagItem} ne $message) {
                	do_log(sprintf("PUNK -> %s tried to capture %s when %s is FLAGITEM",$$source{nickname},$message,$CTFSTATE{TeamTwoFlagItem}));
					player_msg($source,"RESETFLAG");
                    player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
					return;
                }
				if($CTFSTATE{TeamTwoCarrier} ne "") {
					if(lc($$source{nickname}) eq lc($CTFSTATE{TeamTwoCarrier})) {
						# Same player re-picking — server missed the ACTION 5 drop, clear stale carrier
						do_log(sprintf("STATE -> Missed drop detected, clearing carrier %s and allowing re-pickup", $$source{nickname}));
						$CTFSTATE{TeamTwoCarrier} = "";
					} else {
						# Different player — verify the carrier still has it before punishing
						my $carrier_src = getplayer($CTFSTATE{TeamTwoCarrier});
						if($carrier_src) {
							do_log(sprintf("PUNK -> Possible flag capture attempt by %s in %s, verifying carrier hold for %s",
								$$source{nickname}, $$source{sector}, $CTFSTATE{TeamTwoCarrier}));
							player_msg($carrier_src, sprintf("VERIFYCARRIER %s", $CTFSTATE{TeamTwoFlagItem}));
							$CTFSTATE{PendingChallenge}{2} = {
								carrier           => $CTFSTATE{TeamTwoCarrier},
								challenger        => $$source{nickname},
								challenger_sector => $$source{sector},
								flagitem          => $CTFSTATE{TeamTwoFlagItem},
							};
							$CTFSTATE{PendingChallenge}{2}{timer} = Event->timer(
								at => time + 5,
								cb => sub {
									if(exists $CTFSTATE{PendingChallenge}{2}) {
										my $ch = $CTFSTATE{PendingChallenge}{2};
										do_log(sprintf("PUNK -> Carrier verify timed out for %s, denying %s",
											$ch->{carrier}, $ch->{challenger}));
										my $chal = getplayer($ch->{challenger});
										if($chal) {
											player_msg($chal, "RESETFLAG");
											player_msg($chal, sprintf("FLAGITEM %s", $ch->{flagitem}));
										}
										delete $CTFSTATE{PendingChallenge}{2};
									}
								}
							);
							return;
						} else {
							do_log(sprintf("PUNK -> %s tried to capture a flag in %s while one is already captured",
								$$source{nickname}, $$source{sector}));
							player_msg($source,"RESETFLAG");
							player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
							return;
						}
					}
                }
                if($$source{sector} ne $CTFSTATE{TeamTwoFlagSector}) {
                	do_log(sprintf("PUNK -> %s in %s tried to capture flag FLAG: %s",$$source{nickname},$$source{sector},$CTFSTATE{TeamTwoFlagSector}));
					player_msg($source,"RESETFLAG");
                    player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
                    return;
                }
            }
			global_msg(sprintf("%s has stolen Team 1's flag!",$$source{nickname}));
			$CTFSTATE{TeamTwoFlagItem}   = $message;
			$CTFSTATE{TeamTwoFlagSector} = $$source{sector};
			$CTFSTATE{TeamTwoCarrier}    = $$source{nickname};
			carry_history_add(2, $$source{nickname});
			$CTFSTATE{TeamTwoTimeout} = time;
			team_msg(2,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
		}

	}
	
	if ($event eq "5") {
		#Flag Dropped
		if($$source{team} == 1) {
			if($$source{nickname} ne $CTFSTATE{TeamOneCarrier}) { return; }
			global_msg(sprintf("%s has dropped Team 2's flag(%s) in %s",$$source{nickname},$CTFSTATE{TeamOneFlagItem},$$source{sector}));
			$CTFSTATE{TeamOneCarrier} = ""; 
		}
		if($$source{team} == 2) {
            if($$source{nickname} ne $CTFSTATE{TeamTwoCarrier}) { return; }
			global_msg(sprintf("%s has dropped Team 1's flag(%s) in %s",$$source{nickname},$CTFSTATE{TeamTwoFlagItem},$$source{sector}));
			$CTFSTATE{TeamTwoCarrier} = "";
		}
	}
	
	if($event eq "6") {
		#Flag Captured
		if($$source{team} == 1) {
            if($$source{nickname} ne $CTFSTATE{TeamOneCarrier}) { return; }
			global_msg(sprintf("%s has captured Team 2's flag!",$$source{nickname}));
			$CTFSTATE{TeamOneScore}++;
			$$source{bounty} = ($$source{bounty} // 0) + 50;
			stat_add($$source{nickname}, 'captures', 1);
			stat_add($$source{nickname}, 'total_score', 500);
			for my $name (@{$CTFSTATE{TeamOneCarryHistory}}) {
				next if lc($name) eq lc($$source{nickname});
				my $helper = getplayer($name);
				if ($helper) { $$helper{bounty} = ($$helper{bounty} // 0) + 25; }
				else { $CTFSTATE{BountyTable}{$name} = ($CTFSTATE{BountyTable}{$name} // 0) + 25; }
				stat_add($name, 'assists', 1);
				stat_add($name, 'total_score', 250);
			}
			carry_history_clear(1);
			$CTFSTATE{TeamOneCarrier}    = "";
			$CTFSTATE{TeamOneFlagItem}   = "";
			$CTFSTATE{TeamOneFlagSector} = "";
            team_msg(1,"RESETFLAG");
		}
        if($$source{team} == 2) {
        	if($$source{nickname} ne $CTFSTATE{TeamTwoCarrier}) { return; }
            global_msg(sprintf("%s has captured Team 1's flag!",$$source{nickname}));
            $CTFSTATE{TeamTwoScore}++;
            $$source{bounty} = ($$source{bounty} // 0) + 50;
            stat_add($$source{nickname}, 'captures', 1);
            stat_add($$source{nickname}, 'total_score', 500);
            for my $name (@{$CTFSTATE{TeamTwoCarryHistory}}) {
                next if lc($name) eq lc($$source{nickname});
                my $helper = getplayer($name);
                if ($helper) { $$helper{bounty} = ($$helper{bounty} // 0) + 25; }
                else { $CTFSTATE{BountyTable}{$name} = ($CTFSTATE{BountyTable}{$name} // 0) + 25; }
                stat_add($name, 'assists', 1);
                stat_add($name, 'total_score', 250);
            }
            carry_history_clear(2);
			$CTFSTATE{TeamTwoCarrier}    = "";
			$CTFSTATE{TeamTwoFlagItem}   = "";
			$CTFSTATE{TeamTwoFlagSector} = "";
			team_msg(2,"RESETFLAG");
        }
		global_msg(sprintf("-=Scoreboard=- Team 1: %s Team 2: %s",$CTFSTATE{TeamOneScore},$CTFSTATE{TeamTwoScore}));
	}
	
	if($event eq "7") { #Team Chat
		team_msg($$source{team},$message);
	}

	if($event eq "8") { #Carrier verification response
		# --- PendingChallenge path (PUNK carrier-verify) ---
		my $team = $$source{team};
		if(exists $CTFSTATE{PendingChallenge}{$team}) {
			my $ch = $CTFSTATE{PendingChallenge}{$team};
			if(lc($ch->{carrier}) eq lc($$source{nickname})) {
				my $challenger_src = getplayer($ch->{challenger});
				if($message eq "1") {
					# Carrier genuinely has the flag — PUNK the challenger
					do_log(sprintf("PUNK -> Hold verified, %s tried to capture a flag in %s while one is already captured",
						$ch->{challenger}, $ch->{challenger_sector}));
					if($team == 1) { $CTFSTATE{TeamOneTimeout} = time; }
					else            { $CTFSTATE{TeamTwoTimeout} = time; }
					if($challenger_src) {
						player_msg($challenger_src, "RESETFLAG");
						player_msg($challenger_src, sprintf("FLAGITEM %s", $ch->{flagitem}));
					}
				} else {
					# Carrier does not hold the flag — server missed the ACTION 5 drop
					do_log(sprintf("PUNK -> Flag carrier hold empty, removing carrying flag from %s",
						$ch->{carrier}));
					if($team == 1) {
						$CTFSTATE{TeamOneCarrier} = "";
						carry_history_clear(1);
					} else {
						$CTFSTATE{TeamTwoCarrier} = "";
						carry_history_clear(2);
					}
					# If challenger is a different player and still connected, process their pickup now.
					# (Same-player case: VERIFYCARRIER handler in current.lua already cleared
					#  hasEnemyFlag; the next INVENTORY_ADD re-sends ACTION 4 cleanly.)
					if(lc($ch->{carrier}) ne lc($ch->{challenger}) && $challenger_src) {
						if($team == 1) {
							global_msg(sprintf("%s has stolen Team 2's flag!", $ch->{challenger}));
							$CTFSTATE{TeamOneFlagItem}   = $ch->{flagitem};
							$CTFSTATE{TeamOneFlagSector} = $ch->{challenger_sector};
							$CTFSTATE{TeamOneCarrier}    = $ch->{challenger};
							carry_history_add(1, $ch->{challenger});
							team_msg(1, sprintf("FLAGITEM %s", $ch->{flagitem}));
							$CTFSTATE{TeamOneTimeout} = time;
						} else {
							global_msg(sprintf("%s has stolen Team 1's flag!", $ch->{challenger}));
							$CTFSTATE{TeamTwoFlagItem}   = $ch->{flagitem};
							$CTFSTATE{TeamTwoFlagSector} = $ch->{challenger_sector};
							$CTFSTATE{TeamTwoCarrier}    = $ch->{challenger};
							carry_history_add(2, $ch->{challenger});
							team_msg(2, sprintf("FLAGITEM %s", $ch->{flagitem}));
							$CTFSTATE{TeamTwoTimeout} = time;
						}
					}
					state_save();
				}
				$ch->{timer}->cancel() if $ch->{timer};
				delete $CTFSTATE{PendingChallenge}{$team};
				return;
			}
		}
		# --- Existing reconnect-verify path ---
		if($$source{team} == 1 && $CTFSTATE{TeamOneCarrier} eq $$source{nickname}) {
			if($message eq "0") {
				do_log(sprintf("STATE -> %s no longer has the flag, resetting Team 1 flag", $$source{nickname}));
				global_msg(sprintf("%s no longer has Team 2's flag. Flag has been reset.", $$source{nickname}));
				$CTFSTATE{TeamOneCarrier}    = "";
				$CTFSTATE{TeamOneFlagItem}   = "";
				$CTFSTATE{TeamOneFlagSector} = "";
				team_msg(1,"RESETFLAG");
			} else {
				do_log(sprintf("STATE -> %s confirmed still carrying Team 2's flag", $$source{nickname}));
				global_msg(sprintf("%s has reconnected and is still carrying Team 2's flag!", $$source{nickname}));
			}
		}
		if($$source{team} == 2 && $CTFSTATE{TeamTwoCarrier} eq $$source{nickname}) {
			if($message eq "0") {
				do_log(sprintf("STATE -> %s no longer has the flag, resetting Team 2 flag", $$source{nickname}));
				global_msg(sprintf("%s no longer has Team 1's flag. Flag has been reset.", $$source{nickname}));
				$CTFSTATE{TeamTwoCarrier}    = "";
				$CTFSTATE{TeamTwoFlagItem}   = "";
				$CTFSTATE{TeamTwoFlagSector} = "";
				team_msg(2,"RESETFLAG");
			} else {
				do_log(sprintf("STATE -> %s confirmed still carrying Team 1's flag", $$source{nickname}));
				global_msg(sprintf("%s has reconnected and is still carrying Team 1's flag!", $$source{nickname}));
			}
		}
	}

	state_save();
}

sub assign_team {
	#Basic round robin team assignments. Worry about race/guild assigns later if the whole thing actually works
	my $source = $_[0];
	my $team1 = "";
	my $team2 = "";
    my $pool;
	my $query; #SQL Query
    my $row; #Table row data

	if (!$SQL) {
		if ($OPTIONS{DEBUG}) { do_log("ERROR -> assign_team called with no DB connection") }
		player_msg($source,"ERROR: Database unavailable, team assignment failed");
		return;
	}
	db_check();
	if (!$SQL) {
		if ($OPTIONS{DEBUG}) { do_log("ERROR -> assign_team: DB reconnect failed") }
		player_msg($source,"ERROR: Database unavailable, team assignment failed");
		return;
	}

	#Does player have a team already?
	$query = $SQL->prepare("SELECT team FROM player_stat WHERE name=?");
	$query->execute($$source{nickname});

	if($query->rows()) {
		#player has team, assign it 
		$row = $query->fetchrow_hashref();
		$$source{team} = $$row{team};
		if($$row{team} == 1) {
            $CTFSTATE{TeamOnePlayers}++;
			player_msg($source,"SETTEAM 1");
			player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
		} else {
			$CTFSTATE{TeamTwoPlayers}++;
			player_msg($source,"SETTEAM 2");
			player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
		}
	} else {
		#No team — balance based on total DB assignments weighted by current score
		my $t1count = $SQL->selectrow_array("SELECT COUNT(*) FROM player_stat WHERE team=1") // 0;
		my $t2count = $SQL->selectrow_array("SELECT COUNT(*) FROM player_stat WHERE team=2") // 0;
		# Score-weighted effective size: score can tip a tied count but cannot
		# override any actual player count difference (weight cap 0.9 < 1.0).
		my $total_score = $CTFSTATE{TeamOneScore} + $CTFSTATE{TeamTwoScore};
		my ($sw1, $sw2) = (0, 0);
		if ($total_score > 0) {
			$sw1 = ($CTFSTATE{TeamOneScore} / $total_score) * 0.9;
			$sw2 = ($CTFSTATE{TeamTwoScore} / $total_score) * 0.9;
		}
		my $eff1 = $t1count + $sw1;
		my $eff2 = $t2count + $sw2;
		if ($OPTIONS{DEBUG}) { do_log(sprintf("ASSIGN -> DB team counts: Team 1=%d Team 2=%d | Scores: T1=%d T2=%d | Eff: T1=%.3f T2=%.3f", $t1count, $t2count, $CTFSTATE{TeamOneScore}, $CTFSTATE{TeamTwoScore}, $eff1, $eff2)) }
		if($eff1 > $eff2) {
			$$source{team} = 2;
			$CTFSTATE{TeamTwoPlayers}++;
			player_msg($source,"SETTEAM 2");
			player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
		} else {
			$$source{team} = 1;
			$CTFSTATE{TeamOnePlayers}++;
			player_msg($source,"SETTEAM 1");
			player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
		}
		#add player and team assignment to table
		$query = $SQL->prepare("INSERT INTO player_stat SET name=?,team=?");
		$query->execute($$source{nickname},$$source{team});
	}
	# If this player was a flag carrier when the server went down, ask them to verify
	if ($$source{team} == 1 && $CTFSTATE{TeamOneCarrier} eq $$source{nickname}) {
		player_msg($source, sprintf("VERIFYCARRIER %s", $CTFSTATE{TeamOneFlagItem}));
		do_log(sprintf("STATE -> Sent VERIFYCARRIER to %s for %s", $$source{nickname}, $CTFSTATE{TeamOneFlagItem}));
	}
	if ($$source{team} == 2 && $CTFSTATE{TeamTwoCarrier} eq $$source{nickname}) {
		player_msg($source, sprintf("VERIFYCARRIER %s", $CTFSTATE{TeamTwoFlagItem}));
		do_log(sprintf("STATE -> Sent VERIFYCARRIER to %s for %s", $$source{nickname}, $CTFSTATE{TeamTwoFlagItem}));
	}

	foreach $pool (@CPOOL) {
		if($$pool{team} == 1) {
			$team1 = sprintf("%s\"%s\" ",$team1,$$pool{nickname});
		}
		if($$pool{team} == 2) {
            $team2 = sprintf("%s\"%s\" ",$team2,$$pool{nickname});
        }
	}
	#output team rosters to new player
	player_msg($source,"Team 1");
	player_msg($source,$team1);
	player_msg($source,"Team 2");
	player_msg($source,$team2);
	#send Team join to all players
	global_msg(sprintf("%s has joined Team %s",$$source{nickname},$$source{team}));
}

sub server_init() 
{
  $SELECT = new IO::Select;
  $SOCKET = new IO::Socket::INET( Proto     => "tcp",
                                  Listen    => 1000,
                                  LocalPort => "10500",
                                  Reuse     => "1"
                                );
  die "Could not create socket: $!\n" unless $SOCKET;
  $SELECT->add($SOCKET);
}

sub server_cycle()
{
  my $NEW_CONNECTION;
  my @ready;
  my $handle;
  my $data;
  
  @ready = $SELECT->can_read(.1);
  
  foreach $handle (@ready)
  {
    if ($handle == $SOCKET) #new connection time
    {
      $NEW_CONNECTION = $SOCKET->accept();
      $SELECT->add($NEW_CONNECTION);
      send($NEW_CONNECTION, "VERSIONCHECK\n", 0);
      my $nh = $NEW_CONNECTION;
      $PENDING_VERIFY{"$nh"} = Event->timer(
          at => time + 10,
          cb => sub {
              if (exists $PENDING_VERIFY{"$nh"}) {
                  delete $PENDING_VERIFY{"$nh"};
                  if ($OPTIONS{DEBUG}) { do_log("VERSION -> Timeout waiting for version response, disconnecting") }
                  send($nh, "UPDATE Your CTF plugin is outdated or did not respond. Use /lua ReloadInterface() to update, or re-download from voupr if your version is older than 0.2.0.\n", 0);
                  $SELECT->remove($nh);
                  $nh->close();
              }
          }
      );
    } else
    {
      if(sysread($handle, $data, 512) == 0) #read it or close it
      {
        #report error and cleanup any players associated with that connection 
        if ($OPTIONS{DEBUG}) { do_log("ERROR -> READ failed on socket closing connection\n") }
        server_cleanup($handle);
      } else {
        server_recieve($handle,$data);
      }
  
   }
 }
}

sub server_recieve #\$handle,$data
{
   my $handle = $_[0];
   my $data = $_[1];
   my @message;
   my %source;
   my $message;
   my $pool;
   
   @message = split(/\s+/,$data);
   if ($message[0] eq "VERSION") {
       my $ver = $message[1] // "0.0.0";
       if (version_ge($ver, $OPTIONS{MIN_VERSION})) {
           if ($OPTIONS{DEBUG}) { do_log(sprintf("VERSION -> Accepted client version %s", $ver)) }
           if (exists $PENDING_VERIFY{"$handle"}) {
               $PENDING_VERIFY{"$handle"}->cancel();
               delete $PENDING_VERIFY{"$handle"};
           }
           send($handle, "VERSIONOK\n", 0);
       } else {
           if ($OPTIONS{DEBUG}) { do_log(sprintf("VERSION -> Rejected client version %s (minimum %s)", $ver, $OPTIONS{MIN_VERSION})) }
           send($handle, "UPDATE Your CTF plugin version ($ver) is below the minimum required (0.2.0). Use /lua ReloadInterface() to update, or re-download from voupr.\n", 0);
           $SELECT->remove($handle);
           $handle->close();
       }
   }
   if ($message[0] eq "REGISTER") {
       if (exists $PENDING_VERIFY{"$handle"}) {
           if ($OPTIONS{DEBUG}) { do_log("REGISTER -> Rejected, handle has not passed version check") }
           return;
       }
       if ($message[1]) {
           my $existing = getplayer($message[1]);
           if ($existing && $$existing{handle} != $handle) {
               # Reconnecting player on a new socket — evict the stale connection first
               if ($OPTIONS{DEBUG}) { do_log(sprintf("REGISTER -> Evicting stale connection for %s", $message[1])) }
               server_cleanup($$existing{handle});
           }
           if (!is_registered($message[1])) {
               $source{handle} = $handle;
               $source{nickname} = substr($data,(index($data, "",length(sprintf("REGISTER ")))));
               register_player(\%source);
           } else {
               send($handle,"ERROR: Registration failed due to nickname error\n",0);
           }
       } else {
           send($handle,"ERROR: Registration failed due to nickname error\n",0);
       }
   }
   if ($message[0] eq "ACTION") { #Game Message recieved
      if (getsource($handle)) {
         game_action(getsource($handle),$message[1],substr($data,(index($data, "",length(sprintf("ACTION %s ",$message[1]))))));  	
      } else {
	     send($handle,"ERROR: You are not Registered\n",0);
	      if ($OPTIONS{DEBUG}) { do_log("ERROR -> Unregistered player sending Action, disconnecting") }
	     server_cleanup($handle);   
      }
   }
   if ($message[0] eq "LOGOUT") {
      server_cleanup($handle);   	
   }
   if ($message[0] eq "PONG") {
      my $pongsource = getsource($handle);
      server_pong($pongsource) if $pongsource;
   }
   if ($message[0] eq "SCORE") {
      my $scoresource = getsource($handle);
      handle_score_request($scoresource) if $scoresource;
   }

}

sub server_pong {
   my $source = $_[0];

   $$source{ping} = time;
	
}

sub server_cleanup #\$handle
{
    #if a client disconnects compare its handle against players and remove any
    #matching players from the CPOOL
    my $handle = $_[0];
    my @DISCARD;
    my $discard;
    my $pool;

    foreach $pool (@CPOOL)
    {
 #      printf("%s\n",$$pool{nickname});
       if($handle == $$pool{handle}) {
          #Originally I had unregister_player here but that changes the length of
          #@CPOOL and then players are missed so I created a DISCARD array for everyone
          #I need to get rid of.
          push @DISCARD, $pool;
       }
    }
    foreach $discard (@DISCARD) {
       unregister_player($discard); #Good bye!
    }
    $SELECT->remove($handle);
    $handle->close;
}

sub player_msg # \%source,$msg
{
   my $source = $_[0];
   my $msg    = $_[1];
   my $nickname;
   my @lines;
   my $line;
   my $handle;
   
   @lines = split(/[\n\r]+/, $msg);
 
   return if (!$source);

   if($$source{handle})
   {
      foreach $line (@lines)
      {
         if ($OPTIONS{DEBUG}) { do_log(sprintf("SEND %s -> %s", $$source{nickname}, $line)) }
         if (!send($$source{handle}, $line . "\n", 0))
         {
           if ($OPTIONS{DEBUG}) { do_log("ERROR -> SEND failed on socket closing connection\n") }
          server_cleanup($$source{handle});
         }
      }
   }
}   

sub team_msg #\$msg
{
    my $team   = $_[0];
    my $msg    = $_[1];
    my $pool;
    my @failed;

    if ($OPTIONS{DEBUG}) { do_log(sprintf("TEAM %s -> %s",$team, $msg)) }
    foreach $pool (@CPOOL) {
		if($team == $$pool{team}) {
       		if(!send($$pool{handle},$msg . "\n", 0))
           	{
           		if ($OPTIONS{DEBUG}) { do_log("ERROR -> SEND failed on socket closing connection\n") }
               	push @failed, $$pool{handle};
           	}
		}
	}
    server_cleanup($_) for @failed;
}

sub global_msg #\$msg
{
   	my $msg    = $_[0];
   	my $pool;
    my @failed;

	if ($OPTIONS{DEBUG}) { do_log(sprintf("GLOBAL -> %s",$msg)) }
   	foreach $pool (@CPOOL) {
    		if(!send($$pool{handle}, "GLOBAL " . $msg . "\n", 0))
    		{
       			if ($OPTIONS{DEBUG}) { do_log("ERROR -> SEND failed on socket closing connection\n") }
       			push @failed, $$pool{handle};
    		}
   	}
    server_cleanup($_) for @failed;
} 

sub register_player #\%source
{
  #add player to @cpool so when needed we can find this player later
  my $source = $_[0];

  $$source{ping}   = time;
  $$source{pk}     = 0;
  $$source{bounty} = $CTFSTATE{BountyTable}{$$source{nickname}} // 100;
  push @CPOOL, $source;
  player_msg($source,"Logged In.");
  assign_team($source);
  #show_cpool();
}  

sub unregister_player #\%source
{
	#take leaving players out of the hash pool
   	#This does not disconnect the player as the player may be connected to a hub
   	#client that accepts multiple connections

   	my $source = $_[0];
   	my $i;

   	return if (!$source);

   	for(my $i = 0; $i < scalar @CPOOL; $i++)
   	{	
      	if($CPOOL[$i] == $source)
      		{	
         	if ($OPTIONS{DEBUG}) { do_log(sprintf("MAIN -> %s logging off",$$source{nickname})) }
	 		$CTFSTATE{BountyTable}{$$source{nickname}} = $$source{bounty} // 0;
	 		splice(@CPOOL, $i, 1);
	 		global_msg(sprintf("%s on Team %s disconnected from game",$$source{nickname},$$source{team}));
	 		if($$source{team} == 1) {
				#Once checks in place check if player dropping is flag carrier and reset flag
	 			$CTFSTATE{TeamOnePlayers}--;
				if($$source{nickname} eq $CTFSTATE{TeamOneCarrier}) {
					global_msg("Team 1 flag carrier disconnected with flag. Flag Reset");
                    $CTFSTATE{TeamOneCarrier}    = "";
                    $CTFSTATE{TeamOneFlagItem}   = "";
                    $CTFSTATE{TeamOneFlagSector} = "";
					team_msg(1,"RESETFLAG");
				}
	 		}
	 		if($$source{team} == 2) {
	 			$CTFSTATE{TeamTwoPlayers}--;
				if($$source{nickname} eq $CTFSTATE{TeamTwoCarrier}) {
					global_msg("Team 2 flag carrier disconnected with flag. Flag Reset");
                    $CTFSTATE{TeamTwoCarrier}    = "";
                    $CTFSTATE{TeamTwoFlagItem}   = "";
                    $CTFSTATE{TeamTwoFlagSector} = "";
					team_msg(2,"RESETFLAG");
				} 
			}
    	}
   }
   
   #show_cpool();
   return;
}

sub show_cpool
{
   #displays nicks in cpool so I can tell if it is deleting items properly
   my $pool;
   foreach $pool (@CPOOL)
   {
      printf("connection: %s\n",$$pool{nickname});
   }
   return;
}

sub getsource #\$id
{
   my $handle = $_[0];
   my $pool;

   foreach $pool (@CPOOL)
   {
      if($$pool{handle} == $handle)
      {
         return $pool;
      }
   }
   return 0;
}

sub is_registered #\$nickname
{
   my $nickname = $_[0];
   my $pool;

   foreach $pool (@CPOOL)
   {
      if(lc($$pool{nickname}) eq lc($nickname))
      {
         return 1;
      }
   }
   return 0;
}

main();
