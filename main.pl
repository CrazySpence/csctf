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

# uncomment to handle SIGPIPE yourself
$SIG{PIPE} = sub { warn "ERROR -> Broken pipe detected\n" };

require "./log.pl";

my %OPTIONS = ( 
        DD_BUILD  => "0.1.9",
        DEBUG     => 1,
		DB_HOST   => "localhost",
		DB_PORT   => 3306,
		DB_USER   => "",
		DB_PASS   => "",
		DB_DB     => ""
	);

my $SOCKET; #Main Socket
my $SELECT; 
my $MINUTE; #minute timer
my @CPOOL;  #Connection pool hashes
my $SQL; #Database connection handler

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
	TeamOneTimeout    => 0,
	TeamTwoTimeout    => 0,
);

sub main()
{
  if (!$OPTIONS{DEBUG})
  {
     fork and exit;
  } 
  do_log(sprintf('MAIN -> CTF Build %s', $OPTIONS{DD_BUILD}));
  server_init(); #Start the CTF
  db_init();
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
    if ($OPTIONS{DEBUG}) { do_log("DB INIT -> Connecting to MySQL Database ") }
    $data_source = sprintf('DBI:mysql:database=%s;host=%s;port=%d', $OPTIONS{DB_DB}, $OPTIONS{DB_HOST}, $OPTIONS{DB_PORT});
    $SQL = DBI->connect($data_source, $OPTIONS{DB_USER}, $OPTIONS{DB_PASS});
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
            team_msg(1,"RESETFLAG");
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
                        team_msg(2,"RESETFLAG");
                }
        }

	#Check SQL status, reconnect if needed
	if(!$SQL) {
              if ($OPTIONS{DEBUG}) { do_log("Error -> MySQL Database connection lost") }
              db_init();   
        }
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
        #PK Detected
		@arguments = split(/\:+/,$message);
		if ($OPTIONS{DEBUG}) { do_log(sprintf("ACTION -> %s killed %s",$arguments[1],$arguments[0])) }
		$$source{pk} = $$source{pk} + 1;
		#At somepoint check if killing an enemy flag carrier and increase a "defense" stat
	} 
	
	if ($event eq "3") {
		#Flag Carrier died
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
	
	if ($event eq "4") {
		#Flag Created or stolen
		if ($$source{team} == 1) {
			if($CTFSTATE{TeamOneFlagItem} eq "") {
				#new flag
				if($$source{sector} ne $CTFSTATE{TeamTwoStation}) {
					do_log(sprintf("PUNK -> %s in %s tried to create flag FLAG: %s",$$source{nickname},$$source{sector}),$CTFSTATE{TeamTwoStation});
					player_msg("RESETFLAG");
					player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
					return;
				} 
			} else {
				if($CTFSTATE{TeamOneFlagItem} ne $message) {
					do_log(sprintf("PUNK -> %s tried to capture %s when %s is FLAGITEM",$$source{nickname},$message,$CTFSTATE{TeamOneFlagItem}));
					player_msg("RESETFLAG");
                    player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
					return;
				}
				if($CTFSTATE{TeamOneCarrier} ne "") {
					do_log(sprintf("PUNK -> %s tried to capture a flag in %s while one is already captured",$$source{nickname},$$source{sector}));
					player_msg($source,"RESETFLAG");
                   player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
					return;
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
			team_msg(1,sprintf("FLAGITEM %s",$CTFSTATE{TeamOneFlagItem}));
			$CTFSTATE{TeamOneTimeout} = time;
		}
		if($$source{team} == 2) {
			if($CTFSTATE{TeamTwoFlagItem} eq "") {
            	#new flag
                if($$source{sector} ne $CTFSTATE{TeamOneStation}) {
                	do_log(sprintf("PUNK -> %s in %s tried to create flag FLAG: %s",$$source{nickname},$$source{sector}),$CTFSTATE{TeamOneStation});
					player_msg($source,"RESETFLAG");
                    player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
                    return;
                }
            } else {
				if($CTFSTATE{TeamTwoFlagItem} ne $message) {
                	do_log(sprintf("PUNK -> %s tried to capture %s when %s is FLAGITEM",$$source{nickname},$message,$CTFSTATE{TeamTwoFlagItem}));
					player_msg($source,"RESETFLAG");
                    player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
					return;
                }
				if($CTFSTATE{TeamTwoCarrier} ne "") {
                	do_log(sprintf("PUNK -> %s tried to capture a flag in %s while one is already captured",$$source{nickname},$$source{sector}));
					player_msg($source,"RESETFLAG");
                    player_msg($source,sprintf("FLAGITEM %s",$CTFSTATE{TeamTwoFlagItem}));
                    return;
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
			$CTFSTATE{TeamOneCarrier}    = "";
			$CTFSTATE{TeamOneFlagItem}   = "";
			$CTFSTATE{TeamOneFlagSector} = "";
            team_msg(1,"RESETFLAG");
		}
        if($$source{team} == 2) {
        	if($$source{nickname} ne $CTFSTATE{TeamTwoCarrier}) { return; }
            global_msg(sprintf("%s has captured Team 1's flag!",$$source{nickname}));
            $CTFSTATE{TeamTwoScore}++;
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
}

sub assign_team {
	#Basic round robin team assignments. Worry about race/guild assigns later if the whole thing actually works
	my $source = $_[0];
	my $team1 = "";
	my $team2 = "";
    my $pool;
	my $query; #SQL Query
    my $row; #Table row data

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
		#No team, check team count and add new player
		if($CTFSTATE{TeamOnePlayers} > $CTFSTATE{TeamTwoPlayers}) {
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
   if ($message[0] eq "REGISTER") {
       if ($message[1] && !is_registered($message[1])) {
          $source{handle} = $handle;
          $source{nickname} = substr($data,(index($data, "",length(sprintf("REGISTER ")))));
          register_player(\%source);
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
      server_pong(getsource($handle));	
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

    if ($OPTIONS{DEBUG}) { do_log(sprintf("TEAM %s -> %s",$team, $msg)) }
    foreach $pool (@CPOOL) {
		if($team == $$pool{team}) {
       		if(!send($$pool{handle},$msg . "\n", 0))
           	{
           		if ($OPTIONS{DEBUG}) { do_log("ERROR -> SEND failed on socket closing connection\n") }
               	server_cleanup($$pool{handle});
           	}
		}
	}
}

sub global_msg #\$msg
{
   	my $msg    = $_[0];
   	my $pool;
   
	if ($OPTIONS{DEBUG}) { do_log(sprintf("GLOBAL -> %s",$msg)) }
   	foreach $pool (@CPOOL) {
    		if(!send($$pool{handle}, "GLOBAL " . $msg . "\n", 0))
    		{
       			if ($OPTIONS{DEBUG}) { do_log("ERROR -> SEND failed on socket closing connection\n") }
       			server_cleanup($$pool{handle});
    		}		
   	}
} 

sub register_player #\%source
{
  #add player to @cpool so when needed we can find this player later
  my $source = $_[0];
    
  $$source{ping} = time;
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
