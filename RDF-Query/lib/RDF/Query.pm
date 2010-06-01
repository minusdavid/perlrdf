# RDF::Query
# -----------------------------------------------------------------------------

=head1 NAME

RDF::Query - An RDF query implementation of SPARQL/RDQL in Perl for use with RDF::Trine.

=head1 VERSION

This document describes RDF::Query version 2.202, released 30 January 2010.

=head1 SYNOPSIS

 my $query = new RDF::Query ( $sparql );
 my $iterator = $query->execute( $model );
 while (my $row = $iterator->next) {
   print $row->{ var }->as_string;
 }
 
 my $query = new RDF::Query ( $rdql, { lang => 'rdql' } );
 my @rows = $query->execute( $model );

=head1 DESCRIPTION

RDF::Query allows SPARQL and RDQL queries to be run against an RDF model,
returning rows of matching results.

See L<http://www.w3.org/TR/rdf-sparql-query/> for more information on SPARQL.

See L<http://www.w3.org/Submission/2004/SUBM-RDQL-20040109/> for more
information on RDQL.

=head1 CHANGES IN VERSION 2.000

There are many changes in the code between the 1.x and 2.x releases. Most of
these changes will only affect queries that should have raised errors in the
first place (SPARQL parsing, queries that use undefined namespaces, etc.).
Beyond these changes, however, there are some significant API changes that will
affect all users:

=over 4

=item Use of RDF::Trine objects

All nodes and statements returned by RDF::Query are now RDF::Trine objects
(more specifically, RDF::Trine::Node and RDF::Trine::Statement objects). This
differes from RDF::Query 1.x where nodes and statements were of the same type
as the underlying model (Redland nodes from a Redland model and RDF::Core nodes
from an RDF::Core model).

In the past, it was possible to execute a query and not know what type of nodes
were going to be returned, leading to overly verbose code that required
examining all nodes and statements with the bridge object. This new API brings
consistency to both the execution model and client code, greatly simplifying
interaction with query results.

=item Binding Result Values

Binding result values returned by calling C<< $iterator->next >> are now HASH
references (instead of ARRAY references), keyed by variable name. Where prior
code might use this code (modulo model definition and namespace declarations):

  my $sparql = 'SELECT ?name ?homepage WHERE { [ foaf:name ?name ; foaf:homepage ?homepage ] }';
  my $query = RDF::Query->new( $sparql );
  my $iterator = $query->execute( $model );
  while (my $row = $iterator->()) {
    my ($name, $homepage) = @$row;
    # ...
  }

New code using RDF::Query 2.000 and later should instead use:

  my $sparql = 'SELECT ?name ?homepage WHERE { [ foaf:name ?name ; foaf:homepage ?homepage ] }';
  my $query = RDF::Query->new( $sparql );
  my $iterator = $query->execute( $model );
  while (my $row = $iterator->next) {
    my $name = $row->{ name };
    my $homepage = $row->{ homepage };
    # ...
  }

(Also notice the new method calling syntax for retrieving rows.)

=back

=cut

package RDF::Query;

use strict;
use warnings;
no warnings 'redefine';
use Carp qw(carp croak confess);

use Data::Dumper;
use LWP::UserAgent;
use I18N::LangTags;
use List::Util qw(first);
use Scalar::Util qw(blessed reftype looks_like_number);
use DateTime::Format::W3CDTF;

use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($ERROR);

no warnings 'numeric';
use RDF::Trine 0.123;
require RDF::Query::Functions;	# (needs to happen at runtime because some of the functions rely on RDF::Query being fully loaded (to call add_hook(), for example))
								# all the built-in functions including:
								#     datatype casting, language ops, logical ops,
								#     numeric ops, datetime ops, and node type testing
								# also, custom functions including:
								#     jena:sha1sum, jena:now, jena:langeq, jena:listMember
								#     ldodds:Distance, kasei:warn
use RDF::Query::Expression;
use RDF::Query::Algebra;
use RDF::Query::Node qw(iri);
use RDF::Query::Parser::RDQL;
use RDF::Query::Parser::SPARQL;
use RDF::Query::Parser::SPARQL11;
use RDF::Query::Parser::SPARQLP;	# local extensions to SPARQL
use RDF::Query::Compiler::SQL;
use RDF::Query::Error qw(:try);
use RDF::Query::Plan;

######################################################################

our ($VERSION, $DEFAULT_PARSER);
BEGIN {
	$VERSION		= '2.202';
	$DEFAULT_PARSER	= 'sparql';
}


######################################################################

=head1 METHODS

=over 4

=item C<< new ( $query, \%options ) >>

=item C<< new ( $query, $baseuri, $languri, $lang, %options ) >>

Returns a new RDF::Query object for the specified C<$query>.
The query language defaults to SPARQL, but may be set specifically by
specifying either C<$languri> or C<$lang>, whose acceptable values are:

  $lang: 'rdql', 'sparql', 'tsparql', or 'sparqlp'

  $languri: 'http://www.w3.org/TR/rdf-sparql-query/', or 'http://jena.hpl.hp.com/2003/07/query/RDQL'

=cut

sub new {
	my $class	= shift;
	my $query	= shift;

	my ($baseuri, $languri, $lang, %options);
	if (@_ and ref($_[0])) {
		%options	= %{ shift() };
		$lang		= $options{ lang };
		$baseuri	= $options{ base };
	} else {
		($baseuri, $languri, $lang, %options)	= @_;
	}
	$class->clear_error;
	
	my $l		= Log::Log4perl->get_logger("rdf.query");
	no warnings 'uninitialized';
	
	my %names	= (
					rdql		=> 'RDF::Query::Parser::RDQL',
					sparql		=> 'RDF::Query::Parser::SPARQL',
					tsparql		=> 'RDF::Query::Parser::SPARQLP',
					sparqlp		=> 'RDF::Query::Parser::SPARQLP',
					sparql11	=> 'RDF::Query::Parser::SPARQL11',
				);
	my %uris	= (
					'http://jena.hpl.hp.com/2003/07/query/RDQL'	=> 'RDF::Query::Parser::RDQL',
					'http://www.w3.org/TR/rdf-sparql-query/'	=> 'RDF::Query::Parser::SPARQL',
				);
	
	if ($baseuri) {
		$baseuri	= RDF::Query::Node::Resource->new( $baseuri );
	}
	
	my $update	= ($options{update} ? 1 : 0);
	my $pclass	= $names{ $lang } || $uris{ $languri } || $names{ $DEFAULT_PARSER };
	my $parser	= $pclass->new();
	my $parsed	= $parser->parse( $query, $baseuri, $update );
	
	my $self	= $class->_new(
					base			=> $baseuri,
					parser			=> $parser,
					parsed			=> $parsed,
				);
	unless ($parsed->{'triples'}) {
		$class->set_error( $parser->error );
		$l->debug($parser->error);
		return;
	}
	
	if (defined $options{defines}) {
		@{ $self->{options} }{ keys %{ $options{defines} } }	= values %{ $options{defines} };
	}
	
	if ($options{logger}) {
		$l->debug("got external logger");
		$self->{logger}	= $options{logger};
	}
	
	if (my $opt = $options{optimize}) {
		$l->debug("got optimization flag: $opt");
		$self->{optimize}	= $opt;
	} else {
		$self->{optimize}	= 0;
	}
	
	if (my $opt = $options{force_no_optimization}) {
		$l->debug("got force_no_optimization flag");
		$self->{force_no_optimization}	= 1;
	}
	
	if (my $time = $options{optimistic_threshold_time}) {
		$l->debug("got optimistic_threshold_time flag");
		$self->{optimistic_threshold_time}	= $time;
	}
	
	# add rdf as a default namespace to RDQL queries
	if ($pclass eq 'RDF::Query::Parser::RDQL') {
		$self->{parsed}{namespaces}{rdf}	= 'http://www.w3.org/1999/02/22-rdf-syntax-ns#';
	}
	return $self;
}

sub _new {
	my $class	= shift;
	my $self 	= bless( { @_ }, $class );
	return $self;
}

=item C<< get ( $model ) >>

Executes the query using the specified model, and returns the first matching row as a LIST of values.

=cut

sub get {
	my $self	= shift;
	my $stream	= $self->execute( @_ );
	my $row		= $stream->next;
	if (ref($row)) {
		return @{ $row }{ $self->variables };
	} else {
		return undef;
	}
}

=item C<< prepare ( $store ) >>

Prepares the query, constructing a query execution plan, and returns a list
containing ($plan, $context). To execute the plan, call
C<< execute_plan( $plan, $context ) >>.

=cut

sub prepare {
	my $self	= shift;
	my $store	= shift;
	my %args	= @_;
	my $l		= Log::Log4perl->get_logger("rdf.query");
	
	$self->{_query_cache}	= {};	# a new scratch hash for each execution.
	my %bound	= ($args{ 'bind' }) ? %{ $args{ 'bind' } } : ();
	my $errors	= ($args{ 'strict_errors' }) ? 1 : 0;
	my $parsed	= $self->{parsed};
	my @vars	= $self->variables( $parsed );
	
	my $model	= $self->{model} || $self->get_model( $store, %args );
	if ($model) {
		$self->model( $model );
		$l->debug("got model $model");
	} else {
		throw RDF::Query::Error::ModelError ( -text => "Could not create a model object." );
	}
	
	$l->trace("loading data");
	$self->load_data();
	$model		= $self->model();	# reload the model object, because load_data might have changed it.
	
	$l->trace("constructing ExecutionContext");
	my $context	= RDF::Query::ExecutionContext->new(
					bound						=> \%bound,
					model						=> $model,
					query						=> $self,
					base						=> $parsed->{base},
					ns							=> $parsed->{namespaces},
					logger						=> $self->logger,
					optimize					=> $self->{optimize},
					force_no_optimization		=> $self->{force_no_optimization},
					optimistic_threshold_time	=> $self->{optimistic_threshold_time} || 0,
					requested_variables			=> \@vars,
					strict_errors				=> $errors,
				);
	
	$self->{model}		= $model;
	
	$l->trace("getting QEP...");
	my $plan		= $self->query_plan( $context );
	$l->trace("-> done.");
	
	unless ($plan) {
		throw RDF::Query::Error::CompilationError -text => "Query didn't produce a valid execution plan";
	}
	
	return ($plan, $context);
}

=item C<execute ( $store, %args )>

Executes the query using the specified RDF C<< $store >>. If called in a list
context, returns an array of rows, otherwise returns an iterator.

=cut

sub execute {
	my $self	= shift;
	my $store	= shift;
	my %args	= @_;
	my $l		= Log::Log4perl->get_logger("rdf.query");
	$l->debug("executing query with model " . ($store or ''));
	
	my ($plan, $context)	= $self->prepare( $store, %args );
	if ($l->is_trace) {
		$l->trace(">>>>>>>>>>>>>>>>>>>>>>>>>>>>>");
		$l->trace($self->as_sparql);
		$l->trace(">>>>>>>>>>>>>>>>>>>>>>>>>>>>>");
	}
	return $self->execute_plan( $plan, $context );
}

=item C<< execute_plan ( $plan, $context ) >>

Executes the query using the supplied ExecutionContext. If called in a list
context, returns an array of rows, otherwise returns an iterator.

=cut

sub execute_plan {
	my $self	= shift;
	my $plan	= shift;
	my $context	= shift;
	my $model	= $context->model;
	my $parsed	= $self->{parsed};
	my @vars	= $self->variables( $parsed );
	
	my $l		= Log::Log4perl->get_logger("rdf.query");
	
	my $pattern	= $self->pattern;
# 	$l->trace("calling fixup()");
# 	my $cpattern	= $self->fixup();
	
	my @funcs	= $pattern->referenced_functions;
	foreach my $f (@funcs) {
		$self->run_hook( 'http://kasei.us/code/rdf-query/hooks/function_init', $f );
	}
	
	# RUN THE QUERY!

	$l->debug("executing the graph pattern");
	
	my $options	= $parsed->{options} || {};
	
	if ($self->{options}{plan}) {
		warn $plan->sse({}, '');
	}
	
	$plan->execute( $context );
	my $stream	= $plan->as_iterator( $context );
# 	my $stream	= RDF::Trine::Iterator::Bindings->new( sub { $plan->next }, \@vars, distinct => $plan->distinct, sorted_by => $plan->ordered );
	
	$l->debug("performing projection");
	my $expr	= 0;
	foreach my $v (@{ $parsed->{'variables'} }) {
		$expr	= 1 if ($v->isa('RDF::Query::Expression::Alias'));
	}
	
	if ($parsed->{'method'} eq 'DESCRIBE') {
		$stream	= $self->describe( $stream );
	} elsif ($parsed->{'method'} eq 'ASK') {
		$stream	= $self->ask( $stream );
	}
	
	$l->debug("going to call post-execute hook");
	$self->run_hook( 'http://kasei.us/code/rdf-query/hooks/post-execute', $model, $stream );
	
	if (wantarray) {
		return $stream->get_all();
	} else {
		return $stream;
	}
}

=item C<< execute_with_named_graphs ( $store, @uris ) >>

Executes the query using the specified RDF C<< $store >>, loading the contents
of the specified C<@uris> into named graphs immediately prior to matching the
query. Otherwise, acts just like C<< execute >>.

=cut

sub execute_with_named_graphs {
	my $self		= shift;
	my $store		= shift;
	
	my $l		= Log::Log4perl->get_logger("rdf.query");
#	$self->{model}	= $model;
	my $model		= $self->get_model( $store );
	if ($model) {
		$self->model( $model );
	} else {
		throw RDF::Query::Error::ModelError ( -text => "Could not create a model object." );
	}
	
	foreach my $gdata (@_) {
		$l->debug("-> adding graph data " . $gdata->uri_value);
		$self->parse_url( $gdata->uri_value, 1 );
	}
	
	return $self->execute( $model );
}

=begin private

=item C<< query_plan ( $execution_context ) >>

Returns a RDF::Query::Plan object that is (hopefully) the optimal QEP for the
current query.

=end private

=cut

sub query_plan {
	my $self	= shift;
	my $context	= shift;
	my $parsed	= $self->{parsed};
	my %constant_plan;
	if (my $b = $self->{parsed}{bindings}) {
		my $vars	= $b->{vars};
		my $values	= $b->{terms};
		my @names	= map { $_->name } @{ $vars };
		my @constants;
		while (my $values = shift(@{ $b->{terms} })) {
			my %bound;
			@bound{ @names }	= @{ $values };
			my $bound			= RDF::Query::VariableBindings->new( \%bound );
			push(@constants, $bound);
		}
		my $constant_plan	= RDF::Query::Plan::Constant->new( @constants );
		%constant_plan		= ( constants => [ $constant_plan ] );
	}
	
	my $algebra		= $self->pattern;
	my $pclass		= $self->plan_class;
	my @plans		= $pclass->generate_plans( $algebra, $context, %constant_plan );
	
	my $l		= Log::Log4perl->get_logger("rdf.query.plan");
	if (wantarray) {
		return @plans;
	} else {
		my ($plan)	= @plans;	# XXX need to figure out what's the 'best' plan here
		if ($l->is_debug) {
			$l->debug("using query plan: " . $plan->sse({}, ''));
		}
		return $plan;
	}
}

=begin private

=item C<< plan_class >>

Returns the class name for Plan generation. This method should be overloaded by
RDF::Query subclasses if the implementation also provides a subclass of
RDF::Query::Plan.

=end private

=cut

sub plan_class {
	return 'RDF::Query::Plan';
}

=begin private

=item C<describe ( $stream )>

Takes a stream of matching statements and constructs a DESCRIBE graph.

=end private

=cut

sub describe {
	my $self	= shift;
	my $stream	= shift;
	my $model	= $self->model;
	my @nodes;
	my %seen;
	while (my $row = $stream->next) {
		foreach my $v (@{ $self->{parsed}{variables} }) {
			if ($v->isa('RDF::Query::Node::Variable')) {
				my $node	= $row->{ $v->name };
				my $string	= blessed($node) ? $node->as_string : '';
				push(@nodes, $node) unless ($seen{ $string }++);
			} elsif ($v->isa('RDF::Query::Node::Resource')) {
				my $string	= blessed($v) ? $v->as_string : '';
				push(@nodes, $v) unless ($seen{ $string }++);
			}
		}
	}
	
	my @streams;
	$self->{'describe_nodes'}	= [];
	foreach my $node (@nodes) {
		push(@{ $self->{'describe_nodes'} }, $node);
		push(@streams, $model->get_statements( $node ));
		push(@streams, $model->get_statements( undef, undef, $node ));
	}
	
	my $ret	= sub {
		while (@streams) {
			my $val	= $streams[0]->next;
			if (defined $val) {
				return $val;
			} else {
				shift(@streams);
				return undef if (not @streams);
			}
		}
	};
	return RDF::Trine::Iterator::Graph->new( $ret );
}


=begin private

=item C<ask ( $stream )>

Takes a stream of matching statements and returns a boolean query result stream.

=end private

=cut

sub ask {
	my $self	= shift;
	my $stream	= shift;
	my $value	= $stream->next;
	my $bool	= ($value) ? 1 : 0;
	return RDF::Trine::Iterator::Boolean->new( [ $bool ] );
}

######################################################################

=item C<< pattern >>

Returns the RDF::Query::Algebra::GroupGraphPattern algebra pattern for this query.

=cut

sub pattern {
	my $self	= shift;
	my $parsed	= $self->parsed;
	my @triples	= @{ $parsed->{triples} };
	if (scalar(@triples) == 1 and ($triples[0]->isa('RDF::Query::Algebra::GroupGraphPattern')
									or $triples[0]->isa('RDF::Query::Algebra::Filter')
									or $triples[0]->isa('RDF::Query::Algebra::Sort')
									or $triples[0]->isa('RDF::Query::Algebra::Limit')
									or $triples[0]->isa('RDF::Query::Algebra::Offset')
									or $triples[0]->isa('RDF::Query::Algebra::Distinct')
									or $triples[0]->isa('RDF::Query::Algebra::Project')
									or $triples[0]->isa('RDF::Query::Algebra::Construct')
									or $triples[0]->isa('RDF::Query::Algebra::Load')
									or $triples[0]->isa('RDF::Query::Algebra::Clear')
								)) {
		my $ggp		= $triples[0];
		return $ggp;
	} else {
		return RDF::Query::Algebra::GroupGraphPattern->new( @triples );
	}
}

=item C<< as_sparql >>

Returns the query as a string in the SPARQL syntax.

=cut

sub as_sparql {
	my $self	= shift;
	my $parsed	= $self->parsed || {};
	
	my $context	= { namespaces => { %{ $parsed->{namespaces} || {} } } };
	my $method	= $parsed->{method};
	my @vars	= map { $_->as_sparql( $context, '' ) } @{ $parsed->{ variables } };
	my $vars	= join(' ', @vars);
	my $ggp		= $self->pattern;
	
	if ($method =~ /^(LOAD|CLEAR)$/) {
		return $ggp->as_sparql;
	} else {
		{
			my $pvars	= join(' ', sort $ggp->referenced_variables);
			my $svars	= join(' ', sort map { $_->name } @{ $parsed->{ variables } });
			if ($pvars eq $svars) {
				$vars	= '*';
			}
		}
		
		my @ns		= map { "PREFIX $_: <$parsed->{namespaces}{$_}>" } (sort keys %{ $parsed->{namespaces} });
		my @mod;
		if (my $ob = $parsed->{options}{orderby}) {
			push(@mod, 'ORDER BY ' . join(' ', map {
						my ($dir,$v) = @$_;
						($dir eq 'ASC')
							? $v->as_sparql( $context, '' )
							: "${dir}" . $v->as_sparql( $context, '' );
					} @$ob));
		}
		if (my $l = $parsed->{options}{limit}) {
			push(@mod, "LIMIT $l");
		}
		if (my $o = $parsed->{options}{offset}) {
			push(@mod, "OFFSET $o");
		}
		my $mod	= join("\n", @mod);
		
		my $methoddata	= '';
		if ($method eq 'SELECT') {
			$methoddata	= $method;
		} elsif ($method eq 'ASK') {
			$methoddata	= $method;
		} elsif ($method eq 'DESCRIBE') {
			$methoddata		= sprintf("%s %s\nWHERE", $method, $vars);
		}
		
		my $sparql	= sprintf(
			"%s\n%s %s\n%s",
			join("\n", @ns),
			$methoddata,
			$ggp->as_sparql( $context, '' ),
			$mod,
		);
		
		chomp($sparql);
		return $sparql;
	}
}

=item C<< sse >>

Returns the query as a string in the SSE syntax.

=cut

sub sse {
	my $self	= shift;
	my $parsed	= $self->parsed;
	
	my $ggp		= $self->pattern;
	my $ns		= $parsed->{namespaces};
	my $nscount	= scalar(@{ [ keys %$ns ] });
	my $base	= $parsed->{base};
	
	my $indent	= '  ';
	my $context	= { namespaces => $ns, indent => $indent };
	my $indentcount	= 0;
	$indentcount++ if ($base);
	$indentcount++ if ($nscount);
	my $prefix	= $indent x $indentcount;
	
	my $sse	= $ggp->sse( $context, $prefix );
	
	if ($nscount) {
		$sse		= sprintf("(prefix (%s)\n${prefix}%s)", join("\n${indent}" . ' 'x9, map { "(${_}: <$ns->{$_}>)" } (sort keys %$ns)), $sse);
	}
	
	if ($base) {
		$sse	= sprintf("(base <%s>\n${indent}%s)", $base->uri_value, $sse);
	}
	
	chomp($sse);
	return $sse;
}

=item C<< dateparser >>

Returns the DateTime::Format::W3CDTF object associated with this query object.

=cut

sub dateparser {
	my $self	= shift;
	my $parser	= ($self->{dateparser} ||= DateTime::Format::W3CDTF->new);
	return $parser;
}

=begin private

=item C<supports ( $store, $feature )>

Returns a boolean value representing the support of $feature for the given model.

=end private

=cut

sub supports {
	my $self	= shift;
	my $store	= shift;
	my $model	= $self->get_model( $store );
	return $model->supports( @_ );
}


=begin private

=item C<< get_model ( $store ) >>

Returns a model object for the specified RDF C<< $store >>.

=end private

=cut

sub get_model {
	my $self	= shift;
	my $store	= shift;
	my %args	= @_;
	
	my $parsed	= ref($self) ? $self->{parsed} : undef;
	
	my $model;
	if (not $store) {
		$model	= RDF::Trine::Model->temporary_model;
	} elsif (($store->isa('RDF::Trine::Model'))) {
		$model	= $store;
	} elsif ($store->isa('RDF::Redland::Model')) {
		my $s	= RDF::Trine::Store->new_with_object( $store );
		$model	= RDF::Trine::Model->new( $s );
		unless (blessed($model)) {
			Carp::cluck "Failed to construct an RDF::Trine model from $store";
			return;
		}
	} elsif ($store->isa('RDF::Core::Model')) {
		die "RDF::Core is no longer supported";
	} else {
		require Data::Dumper;
		Carp::confess "unknown store type: " . Dumper($store);
	}
	
	return $model;
}

=begin private

=item C<< load_data >>

Loads any external data required by this query (FROM and FROM NAMED clauses).

=end private

=cut

sub load_data {
	my $self	= shift;
	my $model	= $self->model;
	my $parsed	= $self->{parsed};
	
	## LOAD ANY EXTERNAL RDF FILES
	my $sources	= $parsed->{'sources'};
	if (ref($sources) and reftype($sources) eq 'ARRAY') {
		my $need_new_model	= 1;
		my $named_query		= 0;
		
		# put non-named sources first, because they will cause a new model to be
		# constructed. subsequent named data will then be loaded into the correct
		# model object.
		my @sources	= sort { @$a == 2 } @$sources;
		
		foreach my $source (@sources) {
			my $named_source	= (2 == @{$source} and $source->[1] eq 'NAMED');
			if ((not $named_source) and $need_new_model) {
				# query uses FROM <..> clauses, so create a new model so we don't add the statements to a persistent default graph
				$model				= RDF::Trine::Model->temporary_model;
				$self->model( $model );
				$need_new_model	= 0;
			}
			
			my $uri	= $source->[0]->uri_value;
			$self->parse_url( $uri, $named_source );
		}
		$self->run_hook( 'http://kasei.us/code/rdf-query/hooks/post-create-model', $model );
	}
}


=begin private

=item C<< var_or_expr_value ( \%bound, $value ) >>

Returns an (non-variable) RDF::Query::Node value based on C<< $value >>.
If  C<< $value >> is  a node object, it is simply returned. If it is an
RDF::Query::Node::Variable object, the corresponding value in C<< \%bound >>
is returned. If it is an RDF::Query::Expression object, the expression
is evaluated using C<< \%bound >>, and the resulting value is returned.

=end private

=cut

sub var_or_expr_value {
	my $self	= shift;
	my $bound	= shift;
	my $v		= shift;
	if ($v->isa('RDF::Query::Expression')) {
		return $v->evaluate( $self, $bound );
	} elsif ($v->isa('RDF::Trine::Node::Variable')) {
		return $bound->{ $v->name };
	} elsif ($v->isa('RDF::Query::Node')) {
		return $v;
	} else {
		Carp::cluck "not an expression or node value in var_or_expr_value: " . Dumper($v, $bound);
		throw RDF::Query::Error -text => 'Not an expression or node value';
	}
}


=item C<add_function ( $uri, $function )>

Associates the custom function C<$function> (a CODE reference) with the
specified URI, allowing the function to be called by query FILTERs.

=cut

sub add_function {
	my $self	= shift;
	my $uri		= shift;
	my $code	= shift;
	if (ref($self)) {
		$self->{'functions'}{$uri}	= $code;
	} else {
		our %functions;
		$RDF::Query::functions{ $uri }	= $code;
	}
}

=item C<< supported_extensions >>

Returns a list of URLs representing extensions to SPARQL that are supported
by the query engine.

=cut

sub supported_extensions {
	my $self	= shift;
	return qw(
		http://kasei.us/2008/04/sparql-extension/service
		http://kasei.us/2008/04/sparql-extension/service/bloom_filters
		http://kasei.us/2008/04/sparql-extension/unsaid
		http://kasei.us/2008/04/sparql-extension/federate_bindings
		http://kasei.us/2008/04/sparql-extension/select_expression
		http://kasei.us/2008/04/sparql-extension/aggregate
		http://kasei.us/2008/04/sparql-extension/aggregate/count
		http://kasei.us/2008/04/sparql-extension/aggregate/count-distinct
		http://kasei.us/2008/04/sparql-extension/aggregate/min
		http://kasei.us/2008/04/sparql-extension/aggregate/max
	);
}

=item C<< supported_functions >>

Returns a list URLs that may be used as functions in FILTER clauses
(and the SELECT clause if the SPARQLP parser is used).

=cut

sub supported_functions {
	my $self	= shift;
	my @funcs;
	
	if (blessed($self)) {
		push(@funcs, keys %{ $self->{'functions'} });
	}
	
	push(@funcs, keys %RDF::Query::functions);
	return grep { not(/^sparql:/) } @funcs;
}

=begin private

=item C<get_function ( $uri, %args )>

If C<$uri> is associated with a query function, returns a CODE reference
to the function. Otherwise returns C<undef>.

=end private

=cut

sub get_function {
	my $self	= shift;
	my $uri		= shift;
	my %args	= @_;
	my $l		= Log::Log4perl->get_logger("rdf.query");
	$l->debug("trying to get function from $uri");
	
	if (blessed($uri) and $uri->isa('RDF::Query::Node::Resource')) {
		$uri	= $uri->uri_value;
	}
	
	my $func;
	if (ref($self)) {
		$func	= $self->{'functions'}{$uri} || $RDF::Query::functions{ $uri };
	} else {
		$func	= $RDF::Query::functions{ $uri };
	}
	
	if ($func) {
		return $func;
	}
	return;
}


=begin private

=item C<< call_function ( $model, $bound, $uri, @args ) >>

If C<$uri> is associated with a query function, calls the function with the supplied arguments.

=end private

=cut

sub call_function {
	my $self	= shift;
	my $model	= shift;
	my $bound	= shift;
	my $uri		= shift;
	my $l		= Log::Log4perl->get_logger("rdf.query");
	$l->debug("trying to get function from $uri");
	
	my $filter			= RDF::Query::Expression::Function->new( $uri, @_ );
	return $filter->evaluate( $self, $bound );
}

=item C<< add_computed_statement_generator ( $predicate => \&generator ) >>

Adds a statement generator for the given C<< $predicate >> to the query object.
This statement generator will be called as
C<< $generator->( $query, $model, \%bound, $s, $p, $o, $c ) >>
and is expected to return an RDF::Trine::Iterator::Graph object containing
statements with C<< $predicate >>.

=cut

sub add_computed_statement_generator {
	my $self	= shift;
	if (scalar(@_) == 1) {
		throw RDF::Query::Error::MethodInvocationError -text => 'RDF::Query::add_computed_statement_generator must now take two arguments: ( $predicate, \&generator ).';
	}
	my $pred	= shift;
	my $gen		= shift;
	if (blessed($pred)) {
		if ($pred->can('uri_value')) {
			$pred	= $pred->uri_value;
		} else {
			$pred	= "$pred";
		}
	}
	push( @{ $self->{'computed_statement_generators'}{ $pred } }, $gen );
}

=item C<< get_computed_statement_generators ( [ $predicate ] ) >>

Returns an ARRAY reference of computed statement generator closures.

=cut

sub get_computed_statement_generators {
	my $self	= shift;
	if (@_) {
		my $pred	= shift;
		if (blessed($pred)) {
			if ($pred->can('uri_value')) {
				$pred	= $pred->uri_value;
			} else {
				$pred	= "$pred";
			}
		}
		return $self->{'computed_statement_generators'}{ $pred } || [];
	} else {
		return $self->{'computed_statement_generators'} || {};
	}
}

=item C<< add_hook_once ( $hook_uri, $function, $token ) >>

Calls C<< add_hook >> adding the supplied C<< $function >> only once based on
the C<< $token >> identifier. This may be useful if the only code that is able
to add a hook is called many times (in an extension function, for example).

=cut

sub add_hook_once {
	my $self	= shift;
	my $uri		= shift;
	my $code	= shift;
	my $token	= shift;
	unless ($self->{'hooks_once'}{ $token }++) {
		$self->add_hook( $uri, $code );
	}
}

=item C<< add_hook ( $hook_uri, $function ) >>

Associates the custom function C<$function> (a CODE reference) with the
RDF::Query code hook specified by C<$uri>. Each function that has been
associated with a particular hook will be called (in the order they were
registered as hooks) when the hook event occurs. See L</"Defined Hooks">
for more information.

=cut

sub add_hook {
	my $self	= shift;
	my $uri		= shift;
	my $code	= shift;
	if (ref($self)) {
		push(@{ $self->{'hooks'}{$uri} }, $code);
	} else {
		our %hooks;
		push(@{ $RDF::Query::hooks{ $uri } }, $code);
	}
}

=begin private

=item C<get_hooks ( $uri )>

If C<$uri> is associated with any query callback functions ("hooks"),
returns an ARRAY reference to the functions. If no hooks are associated
with C<$uri>, returns a reference to an empty array.

=end private

=cut

sub get_hooks {
	my $self	= shift;
	my $uri		= shift;
	my $func	= $self->{'hooks'}{ $uri }
				|| $RDF::Query::hooks{ $uri }
				|| [];
	return $func;
}

=begin private

=item C<run_hook ( $uri, @args )>

Calls any query callback functions associated with C<$uri>. Each callback
is called with the query object as the first argument, followed by any
caller-supplied arguments from C<@args>.

=end private

=cut

sub run_hook {
	my $self	= shift;
	my $uri		= shift;
	my @args	= @_;
	my $hooks	= $self->get_hooks( $uri );
	foreach my $hook (@$hooks) {
		$hook->( $self, @args );
	}
}

=begin private

=item C<parse_url ( $url, $named )>

Retrieve a remote file by URL, and parse RDF into the RDF store.
If $named is TRUE, associate all parsed triples with a named graph.

=end private

=cut
sub parse_url {
	my $self	= shift;
	my $url		= shift;
	my $named	= shift;
	my $model	= $self->model;
	
	if ($named) {
		RDF::Trine::Parser->parse_url_into_model( $url, $model, context => iri($url) );
	} else {
		RDF::Trine::Parser->parse_url_into_model( $url, $model );
	}
}

=begin private

=item C<variables ()>

Returns a list of the ordered variables the query is selecting.
	
=end private

=cut

sub variables {
	my $self	= shift;
	my $parsed	= shift || $self->parsed;
	my @vars	= map { $_->name }
					grep {
						$_->isa('RDF::Query::Node::Variable') or $_->isa('RDF::Query::Expression::Alias')
					} @{ $parsed->{'variables'} };
	return @vars;
}

=item C<parsed ()>

Returns the parse tree.

=cut

sub parsed {
	my $self	= shift;
	if (@_) {
		$self->{parsed}	= shift;
	}
	return $self->{parsed};
}

=item C<< model >>

Returns the RDF::Trine::Model object for this query.

=cut

sub model {
	my $self	= shift;
	if (@_) {
		$self->{model}	= shift;
	}
	my $model	= $self->{model};
	unless (defined $model) {
		$model	= $self->get_model();
	}
	
	return $model;
}


=item C<< useragent >>

Returns the LWP::UserAgent object used for retrieving web content.

=cut

sub useragent {
	my $self	= shift;
	if (my $ua = $self->{useragent}) {
		return $ua;
	} else {
		my $ua		= LWP::UserAgent->new( agent => "RDF::Query/${VERSION}" );
		$ua->default_headers->push_header( 'Accept' => "application/sparql-results+xml;q=0.9,application/rdf+xml;q=0.5,text/turtle;q=0.7,text/xml" );
		$self->{useragent}	= $ua;
		return $ua;
	}
}


=item C<< log ( $key [, $value ] ) >>

If no logger object is associated with this query object, does nothing.
Otherwise, return or set the corresponding value depending on whether a
C<< $value >> is specified.

=cut

sub log {
	my $self	= shift;
	if (blessed(my $l = $self->{ logger })) {
		$l->log( @_ );
	}
}


=item C<< logger >>

Returns the logger object associated with this query object (if present).

=cut

sub logger {
	my $self	= shift;
	return $self->{ logger };
}

=item C<error ()>

Returns the last error the parser experienced.

=cut

sub error {
	my $self	= shift;
	if (blessed($self)) {
		return $self->{error};
	} else {
		our $_ERROR;
		return $_ERROR;
	}
}

sub _uniq {
	my %seen;
	my @data;
	foreach (@_) {
		push(@data, $_) unless ($seen{ $_ }++);
	}
	return @data;
}

=begin private

=item C<set_error ( $error )>

Sets the object's error variable.

=end private

=cut

sub set_error {
	my $self	= shift;
	my $error	= shift;
	if (blessed($self)) {
		$self->{error}	= $error;
	}
	our $_ERROR	= $error;
}

=begin private

=item C<clear_error ()>

Clears the object's error variable.

=end private

=cut

sub clear_error {
	my $self	= shift;
	if (blessed($self)) {
		$self->{error}	= undef;
	}
	our $_ERROR;
	undef $_ERROR;
}


# =begin private
# 
# =item C<_debug_closure ( $code )>
# 
# Debugging function to print out a deparsed (textual) version of a closure.
# 	
# =end private
# 
# =cut
# 
# sub _debug_closure {
# 	my $closure	= shift;
# 	my $l		= Log::Log4perl->get_logger("rdf.query");
# 	if ($l->is_trace) {
# 		require B::Deparse;
# 		my $deparse	= B::Deparse->new("-p", "-sC");
# 		my $body	= $deparse->coderef2text($closure);
# 		$l->trace("--- --- CLOSURE --- ---");
# 		$l->logcluck($body);
# 	}
# }


1;

__END__

=back

=head1 DEFINED HOOKS

The following hook URIs are defined and may be used to extend the query engine
functionality using the C<< add_hook >> method:

=over 4

=item http://kasei.us/code/rdf-query/hooks/post-create-model

Called after loading all external files to a temporary model in queries that
use FROM and FROM NAMED.

Args: ( $query, $model )

C<$query> is the RDF::Query object.
C<$model> is the RDF::Trine::Model object.

=item http://kasei.us/code/rdf-query/hooks/post-execute

Called immediately before returning a result iterator from the execute method.

Args: ( $query, $model, $iterator )

C<$query> is the RDF::Query object.
C<$model> is the RDF::Trine::Model object.
C<$iterator> is a RDF::Trine::Iterator object.

=back

=head1 SEE ALSO

L<http://www.perlrdf.org/>

=head1 AUTHOR

 Gregory Todd Williams <gwilliams@cpan.org>

=head1 COPYRIGHT

Copyright (c) 2005-2009 Gregory Todd Williams. All rights reserved. This
program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut
