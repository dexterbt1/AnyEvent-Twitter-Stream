use strict;
use warnings;
use AnyEvent;
use AnyEvent::Twitter::Stream;
use AnyEvent::Util qw(guard);
use Data::Dumper;
use JSON;
use Test::More;
use Test::TCP;
use Test::Requires qw(Plack::Builder Plack::Request Plack::Server::AnyEvent Try::Tiny);

my @pattern = (
    {
        method => 'sample',
        option => {},
    },
    {
        method => 'firehose',
        option => {},
    },
    {
        method => 'filter',
        option => {track => 'hogehoge'},
    },
    {
        method => 'filter',
        option => {follow => '123123'},
    },
);

test_tcp(
    client => sub {
        my $port = shift;

        $AnyEvent::Twitter::Stream::STREAMING_SERVER = "127.0.0.1:$port";

        foreach my $item (@pattern) {
            my $destroyed;
            my $received = 0;
            my $count_max = 5;

            note("try $item->{method}");

            {
                my $done = AE::cv;
                my $streamer = AnyEvent::Twitter::Stream->new(
                    username => 'test',
                    password => 's3cr3t',
                    method => $item->{method},
                    timeout => 2,
                    on_tweet => sub {
                        my $tweet = shift;

                        if ($tweet->{hello}) {
                            note(Dumper $tweet);
                            is($tweet->{user}, 'test');
                            is($tweet->{path}, "/1/statuses/$item->{method}.json");
                            is_deeply($tweet->{param}, $item->{option});

                            if (%{$item->{option}}) {
                                is($tweet->{request_method}, 'POST');
                            } else {
                                is($tweet->{request_method}, 'GET');
                            }
                        } else {
                            $done->send, return if $tweet->{count} > $count_max;
                        }

                        $received++;
                    },
                    on_error => sub {
                        my $msg = $_[2] || $_[0];
                        fail("on_error: $msg");
                        $done->send;
                    },
                    %{$item->{option}},
                );
                $streamer->{_guard_for_testing} = guard { $destroyed = 1 };

                $done->recv;
            }

            is($received, $count_max + 1, "received");
            is($destroyed, 1, "destroyed");
        }
    },
    server => sub {
        my $port = shift;

        run_streaming_server($port);
    },
);

done_testing();


sub run_streaming_server {
    my $port = shift;

    my $streaming = sub {
        my $env = shift;
        my $req = Plack::Request->new($env);

        return sub {
            my $respond = shift;

            my $writer = $respond->([200, [
                'Content-Type' => 'application/json',
                'Server' => 'Jetty(6.1.17)',
            ]]);

            $writer->write(encode_json({
                hello => 1,
                path => $req->path,
                request_method => $req->method,
                user => $env->{REMOTE_USER},
                param => $req->parameters,
            }) . "\x0D\x0A");

            my $count = 1;
            my $t; $t = AE::timer(0, 0.2, sub {
                try {
                    $writer->write(encode_json({
                        body => 'x' x 500,
                        count => $count++,
                    }) . "\x0D\x0A");
                } catch {
                    undef $t;
                };
            });
        };
    };

    my $app = builder {
        enable 'Auth::Basic', realm => 'Firehose', authenticator => sub {
            my ($user, $pass) = @_;

            return $user eq 'test' && $pass eq 's3cr3t';
        };
        mount '/1/' => $streaming;
    };

    my $server = Plack::Server::AnyEvent->new(
        host => '127.0.0.1',
        port => $port,
    )->run($app);
}
