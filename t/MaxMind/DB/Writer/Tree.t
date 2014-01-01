use strict;
use warnings;

use Test::More;

use MaxMind::DB::Writer::Tree;

use List::AllUtils qw( all );
use Net::Works::Address;
use Net::Works::Network;
use Scalar::Util qw( blessed );

# We want to have a unique id as part of the data for various tests
my $id = 0;

{
    my @ipv4_subnets
        = Net::Works::Network->range_as_subnets( '1.1.1.1', '1.1.1.32' );

    _test_subnet_permutations( \@ipv4_subnets, 'IPv4' );
}

{
    my @ipv4_subnets = (
        Net::Works::Network->range_as_subnets( '1.1.1.1',  '1.1.1.32' ),
        Net::Works::Network->range_as_subnets( '16.1.1.1', '16.1.3.2' ),
    );

    _test_subnet_permutations( \@ipv4_subnets, 'IPv4 - two distinct ranges' );
}

{
    my @ipv6_subnets = Net::Works::Network->range_as_subnets(
        '::1:ffff:ffff',
        '::2:0000:0059'
    );

    _test_subnet_permutations( \@ipv6_subnets, 'IPv6' );
}

{
    my @ipv6_subnets = (
        Net::Works::Network->range_as_subnets(
            '::1:ffff:ffff',
            '::2:0000:0001'
        ),
        Net::Works::Network->range_as_subnets(
            '2002::abcd',
            '2002::abd4',
        )
    );

    _test_subnet_permutations( \@ipv6_subnets, 'IPv6 - two distinct ranges' );
}

{
    my ( $insert, $expect ) = _ranges_to_data(
        [
            [ '1.1.1.0', '1.1.1.15' ],
            [ '1.1.1.1', '1.1.1.32' ],
        ],
        [
            [ '1.1.1.0', '1.1.1.0' ],
            [ '1.1.1.1', '1.1.1.32' ],
        ],
    );

    _test_tree_as_ipv4_and_ipv6(
        $insert, $expect,
        'overlapping subnets - first is lower'
    );
}

{
    my ( $insert, $expect ) = _ranges_to_data(
        [
            [ '1.1.1.0',  '1.1.1.15' ],
            [ '1.1.1.14', '1.1.1.32' ],
        ],
        [
            [ '1.1.1.0',  '1.1.1.13' ],
            [ '1.1.1.14', '1.1.1.32' ],
        ],
    );

    _test_tree_as_ipv4_and_ipv6(
        $insert, $expect,
        'overlapping subnets - overlap breaks up first subnet into smaller chunks'
    );
}

{
    my ( $insert, $expect ) = _ranges_to_data(
        [
            [ '1.1.1.1', '1.1.1.32' ],
            [ '1.1.1.0', '1.1.1.15' ],
        ],
        [
            [ '1.1.1.0',  '1.1.1.15' ],
            [ '1.1.1.16', '1.1.1.32' ],
        ],
    );

    _test_tree_as_ipv4_and_ipv6(
        $insert, $expect,
        'overlapping subnets - first is higher'
    );
}

{
    my ( $insert, $expect ) = _ranges_to_data(
        [
            [ '1.1.1.0', '1.1.1.15' ],
            [ '1.1.1.1', '1.1.1.14' ],
        ],
        [
            [ '1.1.1.0',  '1.1.1.0' ],
            [ '1.1.1.1',  '1.1.1.14' ],
            [ '1.1.1.15', '1.1.1.15' ],
        ],
    );

    _test_tree_as_ipv4_and_ipv6(
        $insert, $expect,
        'first subnet contains second subnet'
    );
}

{
    my ( $insert, $expect ) = _ranges_to_data(
        [
            [ '1.1.1.1', '1.1.1.14' ],
            [ '1.1.1.0', '1.1.1.15' ],
        ],
        [
            [ '1.1.1.0', '1.1.1.15' ],
        ],
    );

    _test_tree_as_ipv4_and_ipv6(
        $insert, $expect,
        'second subnet contains first subnet'
    );
}

{
    my @pairs = (
        [
            Net::Works::Network->new_from_string( string => '0.0.0.0/32' ),
            { ip => '0.0.0.0' }
        ]
    );

    _test_tree(
        \@pairs,
        \@pairs,
        '0.0.0.0/32 network'
    );
}

{
    my @pairs = (
        [
            Net::Works::Network->new_from_string( string => '::0.0.0.0/128' ),
            { ip => '0.0.0.0' }
        ]
    );

    _test_tree(
        \@pairs,
        \@pairs,
        '::0.0.0.0/128 network'
    );
}

# Tests handling of inserting multiple networks that all have the same data -
# if we end up with a node that has two identical data records, we want to
# remove that node entirely and move the data record up to the parent.
{
    my @distinct_subnets
        = Net::Works::Network->new_from_string( string => '128.0.0.0/1' )
        ->split;

    for my $split_count ( 2 ... 8 ) {
        my $tree = _create_and_insert_duplicates(
            $split_count,
            \@distinct_subnets
        );

        is(
            $tree->node_count(), 2,
            'duplicates merged for split count of ' . $split_count
        );

        for my $ip ( '0.1.2.3', '13.1.0.0', '126.255.255.255' ) {
            my $address
                = Net::Works::Address->new_from_string( string => $ip );
            is(
                $tree->lookup_ip_address($address), 'duplicate',
                qq{$address data value is 'duplicate' for split count $split_count}
            );
        }

        for my $subnet (@distinct_subnets) {
            my $first = $subnet->first();
            my $value = $first->as_string();
            for my $address ( $first, $first->next_ip() ) {
                is(
                    $tree->lookup_ip_address($address), $value,
                    qq{$address data value is $value for split count of $split_count}
                );
            }
        }
    }
}

{
    package TreeIterator;

    sub new {
        bless {}, shift;
    }

    sub process_node_record {
        my $self            = shift;
        my $node_num        = shift;
        my $dir             = shift;
        my $current_ip_num  = shift;
        my $current_netmask = shift;
        my $next_ip_num     = shift;
        my $next_netmask    = shift;
        my $next_node_num   = shift;

        $self->_saw_record( $node_num, $dir );

        return;
    }

    sub process_empty_record {
        my $self            = shift;
        my $node_num        = shift;
        my $dir             = shift;
        my $current_ip_num  = shift;
        my $current_netmask = shift;
        my $next_ip_num     = shift;
        my $next_netmask    = shift;

        $self->_saw_record( $node_num, $dir );

        return;
    }

    sub process_data_record {
        my $self            = shift;
        my $node_num        = shift;
        my $dir             = shift;
        my $current_ip_num  = shift;
        my $current_netmask = shift;
        my $next_ip_num     = shift;
        my $next_netmask    = shift;
        my $value           = shift;

        $self->_saw_record( $node_num, $dir );

        push @{ $self->{values} }, $value;

        return;
    }

    sub _saw_record {
        my $self     = shift;
        my $node_num = shift;
        my $dir      = shift;

        $self->{records}{"$node_num-$dir"}++;

        return;
    }
}

{
    my ( $insert, $expect ) = _ranges_to_data(
        [
            [ '1.1.1.1', '1.1.1.32' ],
        ],
        [
            [ '1.1.1.1', '1.1.1.32' ],
        ],
    );

    my $tree = _make_tree($insert);

    my $iterator = TreeIterator->new();
    $tree->iterate($iterator);

    ok(
        ( all { $_ == 1 } values %{ $iterator->{nodes} } ),
        'each node was visited exactly once'
    );

    ok(
        ( all { $_ == 1 } values %{ $iterator->{records} } ),
        'each record was visited exactly once'
    );

    is(
        scalar values %{ $iterator->{records} },
        $tree->node_count() * 2,
        'saw every record for every node in the tree'
    );

    is_deeply(
        [ sort { $a->{id} <=> $b->{id} } @{ $iterator->{values} } ],
        [
            sort { $a->{id} <=> $b->{id} } map { $_->[1] } @{$expect}
        ],
        'saw expected values for records'
    );
}

{
    my @pairs = (
        [
            Net::Works::Network->new_from_string( string => '1.0.0.0/24' ) =>
                { foo => 42 },
        ],
        (
            map { [ $_ => { bar => 84 } ] }
                Net::Works::Network->range_as_subnets(
                '1.0.0.1' => '1.0.0.15'
                )
        ),
    );

    my @expect = (
        [
            Net::Works::Network->new_from_string( string => '1.0.0.0/32' ) =>
                { foo => 42 }
        ],
        (
            map { [ $_ => { foo => 42, bar => 84 } ] }
                Net::Works::Network->range_as_subnets(
                '1.0.0.1' => '1.0.0.15'
                )
        ),
        (
            map { [ $_ => { foo => 42 } ] }
                Net::Works::Network->range_as_subnets(
                '1.0.0.16' => '1.0.0.255'
                )
        )
    );

    _test_tree(
        \@pairs,
        \@expect,
        'data hashes for records are merged on collision - larger net first',
        { merge_record_collisions => 1 },
    );
}

{
    my @pairs = (
        [
            Net::Works::Network->new_from_string( string => '1.0.0.0/24' ) =>
                { foo => 42 },
        ],
        (
            map { [ $_ => { bar => 84 } ] }
                Net::Works::Network->range_as_subnets(
                '1.0.0.1' => '1.0.0.15'
                )
        ),
        (
            map { [ $_ => { baz => 168 } ] }
                Net::Works::Network->range_as_subnets(
                '1.0.0.9' => '1.0.0.13'
                )
        ),
    );

    my @expect = (
        [
            Net::Works::Network->new_from_string( string => '1.0.0.0/32' ) =>
                { foo => 42 }
        ],
        (
            map { [ $_ => { foo => 42, bar => 84 } ] }
                Net::Works::Network->range_as_subnets(
                '1.0.0.1' => '1.0.0.8'
                )
        ),
        (
            map { [ $_ => { foo => 42, bar => 84, baz => 168 } ] }
                Net::Works::Network->range_as_subnets(
                '1.0.0.9' => '1.0.0.13'
                )
        ),
        (
            map { [ $_ => { foo => 42, bar => 84 } ] }
                Net::Works::Network->range_as_subnets(
                '1.0.0.14' => '1.0.0.15'
                )
        ),
        (
            map { [ $_ => { foo => 42 } ] }
                Net::Works::Network->range_as_subnets(
                '1.0.0.16' => '1.0.0.255'
                )
        )
    );

    _test_tree(
        \@pairs,
        \@expect,
        'data hashes for records are merged on repeated collision - larger net first',
        { merge_record_collisions => 1 },
    );
}

done_testing();

sub _test_subnet_permutations {
    my $subnets = shift;
    my $desc    = shift;

    my @expect = map { [ $_, { foo => 42, id => $id++ } ] } @{$subnets};

    {
        # In this case what we insert into the tree matches the order of what
        # we expect
        _test_tree(
            \@expect, \@expect,
            "ordered subnets - $desc",
        );
    }

    {
        my @reversed = reverse @expect;

        _test_tree(
            \@reversed, \@expect,
            "reversed subnets - $desc"
        );
    }

    {
        my @odd  = grep { $_ % 2 } 0 .. $#expect;
        my @even = grep { !( $_ % 2 ) } 0 .. $#expect;

        my @shuffled = ( @expect[@odd], @expect[ reverse @even ] );

        _test_tree(
            \@shuffled, \@expect,
            "shuffled subnets - $desc"
        );
    }

    {
        my @duplicated = ( @expect, @expect );

        _test_tree(
            \@duplicated, \@expect,
            "duplicated subnets - $desc"
        );
    }
}

sub _test_tree {
    my $insert_pairs = shift;
    my $expect_pairs = shift;
    my $desc         = shift;
    my $args         = shift;

    my $tree = _make_tree( $insert_pairs, $args );

    _test_expected_data( $tree, $expect_pairs, $desc );

    for my $raw (qw( 1.1.1.33 8.9.10.11 ffff::1 )) {
        my $address = Net::Works::Address->new_from_string(
            string  => $raw,
            version => ( $raw =~ /::/ ? 6 : 4 ),
        );

        is(
            $tree->lookup_ip_address($address),
            undef,
            "The address $address is not in the tree - $desc"
        );
    }
}

sub _make_tree {
    my $pairs = shift;
    my $args  = shift;

    my $tree = MaxMind::DB::Writer::Tree->new(
        ip_version    => $pairs->[0][0]->version(),
        record_size   => 24,
        database_type => 'Test',
        languages     => ['en'],
        description   => { en => 'Test tree' },
        %{ $args || {} },
    );

    for my $pair ( @{$pairs} ) {
        my ( $subnet, $data ) = @{$pair};

        $tree->insert_network( $subnet, $data );
    }

    return $tree;
}

sub _test_expected_data {
    my $tree   = shift;
    my $expect = shift;
    my $desc   = shift;

    foreach my $pair ( @{$expect} ) {
        my ( $subnet, $data ) = @{$pair};

        my $iter = $subnet->iterator();
        while ( my $address = $iter->() ) {
            is_deeply(
                $tree->lookup_ip_address($address),
                $data,
                "Got expected data for $address - $desc"
            );
        }
    }
}

sub _ranges_to_data {
    my $insert_ranges = shift;
    my $expect_ranges = shift;

    my %ip_to_data;
    my @insert;
    for my $subnet ( map { Net::Works::Network->range_as_subnets( @{$_} ), }
        @{$insert_ranges} ) {

        my $data = {
            x  => 'foo',
            id => $id,
        };

        push @insert, [ $subnet, $data ];

        my $iter = $subnet->iterator();
        while ( my $ip = $iter->() ) {
            $ip_to_data{ $ip->as_string() } = $data;
        }

        $id++;
    }

    my @expect = (
        map { [ $_, $ip_to_data{ $_->first()->as_string() } ] } (
            map { Net::Works::Network->range_as_subnets( @{$_} ), }
                @{$expect_ranges}
        )
    );

    return \@insert, \@expect;
}

sub _test_tree_as_ipv4_and_ipv6 {
    my $insert = shift;
    my $expect = shift;
    my $desc   = shift;

    _test_tree( $insert, $expect, $desc );
    _test_tree_as_ipv6( $insert, $expect, $desc );
}

sub _test_tree_as_ipv6 {
    my $insert = shift;
    my $expect = shift;
    my $desc   = shift;

    $insert = [ map { [ _subnet_as_v6( $_->[0] ), $_->[1] ] } @{$insert} ];
    $expect = [ map { [ _subnet_as_v6( $_->[0] ), $_->[1] ] } @{$expect} ];

    _test_tree( $insert, $expect, $desc . ' - IPv6' );
}

sub _subnet_as_v6 {
    my $subnet = shift;

    my $subnet_string
        = '::'
        . $subnet->first()->as_string() . '/'
        . ( $subnet->mask_length() + 96 );

    return Net::Works::Network->new_from_string(
        string  => $subnet_string,
        version => 6,
    );
}

sub _create_and_insert_duplicates {
    my $split_count      = shift;
    my $distinct_subnets = shift;

    my $tree = _make_tree(
        [ map { [ $_, $_->as_string() ] } @{$distinct_subnets} ] );

    my @duplicate_data_subnets
        = ( Net::Works::Network->new_from_string( string => '0.0.0.0/1' ) );

    @duplicate_data_subnets = map { $_->split() } @duplicate_data_subnets
        for ( 1 .. $split_count );

    for my $subnet (@duplicate_data_subnets) {
        $tree->insert_network( $subnet, 'duplicate' );
    }

    for my $subnet (@$distinct_subnets) {
        $tree->insert_network( $subnet, $subnet->first()->as_string() );
    }

    return $tree;
}
