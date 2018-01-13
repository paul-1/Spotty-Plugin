package Plugins::Spotty::Connect;

use strict;

use Proc::Background;

use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant CONNECT_HELPER_VERSION => '0.9.0';
use constant SEEK_THRESHOLD => 3;
use constant DAEMON_WATCHDOG_INTERVAL => 60;
use constant HISTORY_KEY => 'spotty-connect-history';

my $cache = Slim::Utils::Cache->new();
my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');

my %helperInstances;
my %helperBins;
my $initialized;

sub init {
	my ($class) = @_;

	if (main::WEBUI && !$initialized) {
		require Plugins::Spotty::PlayerSettings;
		Plugins::Spotty::PlayerSettings->new();
	}
	
	return unless $class->canSpotifyConnect('dontInit');
	
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch(['spottyconnect','_cmd'],
	                                                            [1, 0, 1, \&_connectEvent]
	);
	
	# listen to playlist change events so we know when Spotify Connect mode ends
	Slim::Control::Request::subscribe(\&_onNewSong, [['playlist'], ['newsong']]);
	
	# we want to tell the Spotify controller to pause playback when we pause locally
	Slim::Control::Request::subscribe(\&_onPause, [['playlist'], ['pause', 'stop']]);
	
	# we want to tell the Spotify about local volume changes
	Slim::Control::Request::subscribe(\&_onVolume, [['mixer'], ['volume']]);
	
	# manage helper application instances
	Slim::Control::Request::subscribe(\&initHelpers, [['client'], ['new', 'disconnect']]);
	
	# start/stop helpers when the Connect flag changes
	$prefs->setChange(\&initHelpers, 'enableSpotifyConnect');
	
	# re-initialize helpers when the active account for a player changes
	$prefs->setChange(sub {
		my ($pref, $new, $client, $old) = @_;
		
		return unless $client && $client->id;
		
		main::INFOLOG && $log->is_info && $log->info("Spotify Account for player " . $client->id . " has changed - re-initialize Connect helper");
		__PACKAGE__->stopHelper($client->id);
		initHelpers();
	}, 'account');

	$initialized = 1;
}

sub canSpotifyConnect {
	my ($class, $dontInit) = @_;
	
	# we need a minimum helper application version
	if ( !Slim::Utils::Versions->checkVersion(Plugins::Spotty::Plugin->getHelperVersion(), CONNECT_HELPER_VERSION, 10) ) {
		$log->error("Cannot support Spotty Connect, need at least helper version " . CONNECT_HELPER_VERSION);
		return;
	}
	
	__PACKAGE__->init() unless $initialized || $dontInit;
	
	return 1;
}

sub isSpotifyConnect {
	my ( $class, $client ) = @_;
	
	return unless $client;
	$client = $client->master;
	my $song = $client->playingSong();
	
	return unless $client->pluginData('SpotifyConnect');
	
	return $client->pluginData('newTrack') || ($song ? $song->pluginData('SpotifyConnect') : undef) ? 1 : 0; 
}

sub setSpotifyConnect {
	my ( $class, $client ) = @_;
	
	return unless $client;

	$client = $client->master;
	my $song = $client->playingSong();
	
	# state on song: need to know whether we're currently in Connect mode. Is lost when new track plays.
	$song->pluginData( SpotifyConnect => time() );
	# state on client: need to know whether we've been in Connect mode. If this is set, then we've been playing from Connect, but are no more.
	$client->pluginData( SpotifyConnect => 1 );
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my $client = $song->master;

	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);			

	if ( $client->pluginData('newTrack') ) {
		main::INFOLOG && $log->is_info && $log->info("Don't get next track as we got called by a play track event from spotty");
		$class->setSpotifyConnect($client);
		$client->pluginData( newTrack => 0 );
		$successCb->();
	}
	else {
		main::INFOLOG && $log->is_info && $log->info("We're approaching the end of a track - get the next track");

		$client->pluginData( newTrack => 1 );
		
		# add current track to the history
		my $history = $cache->get(HISTORY_KEY) || {};
		$history->{$song->track->url}++;
		$cache->set(HISTORY_KEY, $history);

		$spotty->playerNext(sub {
			$spotty->player(sub {
				my ($result) = @_;
				
				if ( $result && ref $result && (my $uri = $result->{item}->{uri}) ) {
					main::INFOLOG && $log->is_info && $log->info("Got a new track to be played next: $uri");
					
					$uri =~ s/^(spotify:)(track:.*)/$1\/\/$2/;

					# stop playback if we've played this track before. It's likely trying to start over.
					if ( $history->{$uri} && !($result->{repeat_state} && $result->{repeat_state} eq 'on')) {
						main::INFOLOG && $log->is_info && $log->info('Stopping playback, as we have likely reached the end of our context (playlist, album, ...)');
						
						# set a timer to stop playback at the end of the track
						my $remaining = $client->controller()->playingSongDuration() - Slim::Player::Source::songTime($client);
						
						Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining, sub {
							$spotty->playerPause(undef, $client->id);
						});
					}
					else {
						$song->track->url($uri);
						$class->setSpotifyConnect($client);
					}
					
					$successCb->();
				}
			});
		});
	}
}

sub _onNewSong {
	my $request = shift;

	return if $request->source && $request->source eq __PACKAGE__;

	my $client  = $request->client();
	return if !defined $client;
	$client = $client->master;

	return if __PACKAGE__->isSpotifyConnect($client);
	
	return unless $client->pluginData('SpotifyConnect');
	
	main::INFOLOG && $log->is_info && $log->info("Got a new track event, but this is no longer Spotify Connect");
	$client->playingSong()->pluginData( SpotifyConnect => 0 );
	$client->pluginData( SpotifyConnect => 0 );
	Plugins::Spotty::Plugin->getAPIHandler($client)->playerPause(undef, $client->id);
}

sub _onPause {
	my $request = shift;

	return if $request->source && $request->source eq __PACKAGE__;

	my $client  = $request->client();
	return if !defined $client;
	$client = $client->master;

	return if !__PACKAGE__->isSpotifyConnect($client);

	if ( $request->isCommand([['playlist'],['stop']]) && $client->playingSong()->pluginData('SpotifyConnect') > time() - 5 ) {
		main::INFOLOG && $log->is_info && $log->info("Got a stop event within 5s after start of a new track - do NOT tell Spotify Connect controller to pause");
		return;
	}
	
	main::INFOLOG && $log->is_info && $log->info("Got a pause event - tell Spotify Connect controller to pause, too");
	Plugins::Spotty::Plugin->getAPIHandler($client)->playerPause(undef, $client->id);
}

sub _onVolume {
	my $request = shift;
	
	return if $request->source && $request->source eq __PACKAGE__;
	
	my $client  = $request->client();
	return if !defined $client;
	$client = $client->master;

	return if !__PACKAGE__->isSpotifyConnect($client);
	
	my $volume = $client->volume;
	
	# buffer volume change events, as they often come in bursts
	Slim::Utils::Timers::killTimers($client, \&_bufferedSetVolume);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.5, \&_bufferedSetVolume, $volume);
}

sub _bufferedSetVolume {
	my ($client, $volume) = @_;
	main::INFOLOG && $log->is_info && $log->info("Got a volume event - tell Spotify Connect controller to adjust volume, too: $volume");
	Plugins::Spotty::Plugin->getAPIHandler($client)->playerVolume(undef, $client->id, $volume);
}

sub _connectEvent {
	my $request = shift;
	my $client = $request->client()->master;
	
	if ( $client->pluginData('newTrack') ) {
		$client->pluginData( newTrack => 0 );
		return;
	}

	my $cmd = $request->getParam('_cmd');
	
	main::INFOLOG && $log->is_info && $log->info("Got called from spotty helper: $cmd");
	
	if ( $cmd eq 'volume' && !($request->source && $request->source eq __PACKAGE__) ) {
		my $volume = $request->getParam('_p2');
		
		return unless defined $volume;
		
		# we don't let spotty handle volume directly to prevent getting caught in a call loop
		my $request = Slim::Control::Request->new( $client->id, [ 'mixer', 'volume', $volume ] );
		$request->source(__PACKAGE__);
		$request->execute();
		
		return;
	}

	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);			

	$spotty->player(sub {
		my ($result) = @_;
		
		my $song = $client->playingSong();
		my $streamUrl = ($song ? $song->streamUrl : '') || '';
		$streamUrl =~ s/\/\///;
		
		$result ||= {};
		
		main::DEBUGLOG && $log->is_debug && $log->debug("Current Connect state: \n" . Data::Dump::dump($result, $cmd));
		
		# in case of a change event we need to figure out what actually changed...
		if ( $cmd =~ /change/ && $result && ref $result && (($streamUrl ne $result->{track}->{uri} && $result->{is_playing}) || !__PACKAGE__->isSpotifyConnect($client)) ) {
			main::INFOLOG && $log->is_info && $log->info("Got a $cmd event, but actually this is a play next track event");
			$cmd = 'start';
		}

		if ( $cmd eq 'start' && $result->{track} ) {
			if ( $streamUrl ne $result->{track}->{uri} || !__PACKAGE__->isSpotifyConnect($client) ) {
				main::INFOLOG && $log->is_info && $log->info("Got a new track to be played: " . $result->{track}->{uri});

				# sync volume up to spotify if we just got connected
				if ( !$client->pluginData('SpotifyConnect') ) {
					Plugins::Spotty::Plugin->getAPIHandler($client)->playerVolume(undef, $client->id, $client->volume);
				}

				# Sometimes we want to know whether we're in Spotify Connect mode or not
				$client->pluginData( SpotifyConnect => 1 );
				$client->pluginData( newTrack => 1 );

				my $request = $client->execute( [ 'playlist', 'play', $result->{track}->{uri} ] );
				$request->source(__PACKAGE__);
				
				# on interactive Spotify Connect use we're going to reset the play history.
				# this isn't really solving the problem of lack of context. But it's better than nothing...
				$cache->remove(HISTORY_KEY);
				
				# if status is already more than 10s in, then do seek
				if ( $result->{progress} && $result->{progress} > 10 ) {
					$client->execute( ['time', $result->{progress}] );
				}
			}
			elsif ( !$client->isPlaying ) {
				main::INFOLOG && $log->is_info && $log->info("Got to resume playback");
				__PACKAGE__->setSpotifyConnect($client);
				my $request = $client->execute(['play']);
				$request->source(__PACKAGE__);
			}
		}
		elsif ( $cmd eq 'stop' && $result->{device} ) {
			my $clientId = $client->id;
			
			# if we're playing, got a stop event, and current Connect device is us, then pause
			if ( $client->isPlaying && ($result->{device}->{id} == Plugins::Spotty::API->idFromMac($clientId) || $result->{device}->{name} eq $client->name) && __PACKAGE__->isSpotifyConnect($client) ) {
				main::INFOLOG && $log->is_info && $log->info("Spotify told us to pause");
			} 
			# if we're playing, got a stop event, and current Connect device is NOT us, then 
			# disable Connect and let the track end
			elsif ( $client->isPlaying ) {
				main::INFOLOG && $log->is_info && $log->info("Spotify told us to pause, but current player is not Connect target");
				$client->playingSong()->pluginData( SpotifyConnect => 0 );
				$client->pluginData( SpotifyConnect => 0 );
			}

			my $request = Slim::Control::Request->new( $client->id, ['pause', 1] );
			$request->source(__PACKAGE__);
			$request->execute();
		}
		elsif ( $cmd eq 'change' ) {
			# seeking event from Spotify - we would only seek if the difference was larger than x seconds, as we'll never be perfectly in sync
			if ( $client->isPlaying && abs($result->{progress} - Slim::Player::Source::songTime($client)) > SEEK_THRESHOLD ) {
				$client->execute( ['time', $result->{progress}] );
			}
		}
#		elsif ( $cmd eq 'volume' && $result && $result->{device} && (my $volume = $result->{device}->{volume_percent}) ) {
#			# we don't let spotty handle volume directly to prevent getting caught in a call loop
#			my $request = Slim::Control::Request->new( $client->id, [ 'mixer', 'volume', $volume ] );
#			$request->source(__PACKAGE__);
#			$request->execute();
#		}
		elsif (main::INFOLOG && $log->is_info) {
			$log->info("Unknown command called? $cmd\n" . Data::Dump::dump($result));
		}
	});
}

sub initHelpers {
	my $class = __PACKAGE__;
	
	Slim::Utils::Timers::killTimers( $class, \&initHelpers );

	main::DEBUGLOG && $log->is_debug && $log->debug("Initializing Spotty Connect helper daemons...");

	# shut down orphaned instances
	$class->shutdownHelpers('inactive-only');

	for my $client ( Slim::Player::Client::clients() ) {
		my $clientId = $client->id;

		if ( $prefs->client($client)->get('enableSpotifyConnect') ) {
			# sometimes Connect players disappear without the process crashing - check against the list of Connect players as reported by Spotify
			my $needConnectPlayer = !Plugins::Spotty::API->idFromMac($clientId);
			
			if ( $needConnectPlayer || !$helperInstances{$clientId} || !$helperInstances{$clientId}->alive ) {
				main::INFOLOG && $log->is_info && $log->info("Need to start Connect daemon for $clientId");
				
				my $account;
				if ($needConnectPlayer) {
					$account = Plugins::Spotty::Plugin->getAccount($client);
					Slim::Utils::Timers::killTimers( $account, \&_getConnectPlayers );
					$class->stopHelper($clientId);
				}
				$class->startHelper($client);
				
				# update the list of connected players if needed
				Slim::Utils::Timers::setTimer( $account, time() + 5, \&_getConnectPlayers, $client ) if $account && $needConnectPlayer;
			}
		}
		else {
			$class->stopHelper($clientId);
		}
	}

    Slim::Utils::Timers::setTimer( $class, time() + DAEMON_WATCHDOG_INTERVAL, \&initHelpers );
}

sub _getConnectPlayers {
	my ($account, $client) = @_;

	Slim::Utils::Timers::killTimers( $account, \&_getConnectPlayers );
	
	if ( !Plugins::Spotty::API->idFromMac($client->id) ) {
		Plugins::Spotty::Plugin->getAPIHandler($client)->devices();
	}
}

sub startHelper {
	my ($class, $client) = @_;
	
	my $clientId = $client->id;
	
	# no need to restart if it's already there
	my $helper = $helperInstances{$clientId};
	return 1 if $helper && $helper->alive;

	my $helperPath = Plugins::Spotty::Plugin->getHelper();

	if ( !($helper && $helper->alive) ) {
		my @helperArgs = (
			'-c', Plugins::Spotty::Plugin->cacheFolder( Plugins::Spotty::Plugin->getAccount($client) ),
			'-n', $client->name,
			'--disable-discovery',
			'--disable-audio-cache',
			'--bitrate', 96,
			'--player-mac', $clientId,
			'--lms', Slim::Utils::Network::serverAddr() . ':' . preferences('server')->get('httpport'),
		);

		main::INFOLOG && $log->is_info && $log->info("Starting Spotty Connect deamon: \n$helperPath " . join(' ', @helperArgs));

		eval { 
			$helper = $helperInstances{$clientId} = Proc::Background->new(
				{ 'die_upon_destroy' => 1 },
				$helperPath,
				@helperArgs
			);
		};

		if ($@) {
			$log->warn("Failed to launch the Spotty Connect deamon: $@");
		}
	}

	return $helper && $helper->alive;
}

sub stopHelper {
	my ($class, $clientId) = @_;
	
	my $helper = $helperInstances{$clientId};
	
	if ($helper && $helper->alive) {
		main::INFOLOG && $log->is_info && $log->info("Quitting Spotty Connect daemon for $clientId");
		$helper->die;
	}
}

sub shutdownHelpers {
	my ($class, $inactiveOnly) = @_;
	
	my %clientIds = map { $_->id => 1 } Slim::Player::Client::clients() if $inactiveOnly;
	
	foreach my $clientId ( keys %helperInstances ) {
		next if $clientIds{$clientId};
		$class->stopHelper($clientId);
	}

	Slim::Utils::Timers::killTimers( $class, \&initHelpers );
}

1;