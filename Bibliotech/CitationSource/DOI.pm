# Copyright 2005 Nature Publishing Group
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# The Bibliotech::CitationSource::DOI class recognises DOIs
# in the URI-like doi: construction or as http://dx.doi.org/...
# URLs and queries CrossRef for the metadata.
#
# NOTE: This module relies on membership of CrossRef.  You must
# have a CrossRef web services query account and permission to
# use it for this purpose. More details via:
# http://www.crossref.org/ 

package Bibliotech::CitationSource::DOI;

use strict;
use warnings;

use Bibliotech::CitationSource;
use base 'Bibliotech::CitationSource';

use Bibliotech::CitationSource::Simple;

use XML::LibXML;
use HTML::Entities;
use URI::Escape;
use Encode qw/decode_utf8/;
use constant CR_URL => 'http://doi.crossref.org/servlet/query';

sub api_version {
  1;
}

sub name {
  'DOI';
}

sub version {
  '2.0';
}

sub understands {
  my ($self, $uri) = @_;
  $self->{'query_result'} = undef;  # reset query result cache
  return 0 unless $self->crossref_account;
  return 1 if $self->get_doi($uri);
  return 0;
}

sub filter {
  my ($self, $uri) = @_;
  my $doi = $self->get_doi($uri) or return undef;
  $self->errstr(_not_found_message($doi)), return '' unless $self->resolved($doi);
  $doi =~ s!\#!\%23!g;  # in case doi contains a hash
  my $new_uri = URI->new('http://dx.doi.org/'.$doi);
  return $new_uri->eq($uri) ? undef : $new_uri;
}

sub _not_found_message {
  my $doi = shift;
  return "DOI $doi cannot be resolved. ".
         "It may not be in the CrossRef database, or you may have mis-entered it. ".
	 "Please check it and try again.\n";
}

sub citations {
  my ($self, $uri) = @_;

  my $doi = $self->get_doi($uri) or return undef;

  return $self->citations_id({doi => $doi});
}

sub citations_id {
  my ($self, $id_hashref) = @_;

  my $doi = $id_hashref->{doi} or return undef;

  my $query_result = $self->query_result($doi) or return undef;

  unless ($query_result->{'journal'} && $query_result->{'pubdate'}) {
    $self->errstr('Insufficient metadata extracted for doi:'.$doi);
    return undef;
  }

  return Bibliotech::CitationSource::ResultList->new(Bibliotech::CitationSource::Result::Simple->new($query_result));
}

sub resolved {
  my ($self, $doi) = @_;
  my $query_result = $self->query_result($doi);
  return 1 if defined $query_result && $query_result->{'status'} && $query_result->{'status'} eq 'resolved';
  return 0;
}

sub query_result {
  my ($self, $doi) = @_;
  return $self->{'query_result'}->{$doi} if $self->{'query_result'}->{$doi};
  return $self->{'query_result'}->{$doi} = $self->query_result_calc($doi);
}

sub query_result_calc {
  my ($self, $doi) = @_;
  return $self->parse_crossref_xml($self->crossref_query($doi), $doi) || undef;
}

sub parse_crossref_xml {
  my ($self, $xml, $doi) = @_;
  return unless $xml;
  my $lib = XML::LibXML->new;
  my ($ok, $val) = $self->catch_transient_errstr(sub {
    local $_ = $xml;
    s/<crossref_result.*?>/<crossref_result>/;
    my $tree = eval { $lib->parse_string($_) };
    $@                                                   and die "CrossRef XML parse failed: $@\n";
    defined $tree                                         or die "CrossRef XML parse failed\n";
    my $root = $tree->getDocumentElement                  or die 'no root';
    my $node = 'query_result/body/query/';
    my $val_sub = sub { $root->findvalue($node.shift) };
    lc($val_sub->('doi')) eq lc($doi)                     or die "DOI mismatch\n";
    return $val_sub;
  });
  $ok or return;
  return {status  => 'unresolved'} if $val->('@status') eq 'unresolved';
  return {status  => 'resolved',
	  pubdate => $val->('year') || undef,
	  journal => { name => decode_entities($val->('journal_title')) || undef,
		       issn => $val->('issn[@type="print"]') || undef},
	  page    => $val->('first_page') || undef,
	  volume  => $val->('volume') || undef,
	  issue   => $val->('issue') || undef,
	  pubdate => $val->('year') || undef,
	  title   => decode_entities($val->('article_title')) || undef,
	  doi     => $doi}; 
}

sub _get_raw_doi_from_uri {
  my $uri = shift;
  $uri =~ /^10\./ and return "$uri";
  my $scheme = $uri->scheme;
  local $_   = $uri->path;
  return $_                         if $scheme eq 'doi';
  return do { m|^doi/(.*)$|i; $1; } if $scheme eq 'info';
  return do { m|^/(.*)$|; $1; }     if $scheme eq 'http' and $uri->host eq 'dx.doi.org';
  return;
}

sub _clean_raw_doi_from_uri {
  local $_ = shift or return;
  s/^doi://i;                  # sometimes repeated in dx.doi.org URL
  m/^10\./         or return;  # sanity check; if this fails, don't bother
  $_ = uri_unescape($_);       # resolve %A0 type entities
  $_ = decode_utf8($_) || $_;  # spec says all printable UCS-2 characters are valid
  s/[[:cntrl:]]//g;            # remove control characters
  s/\s+$//g;                   # remove trailing whitespace
  return lc($_);               # spec says case-insensitive so standardize lower
}

sub get_doi {
  my ($self, $uri) = @_;
  return _clean_raw_doi_from_uri(_get_raw_doi_from_uri($uri));
}

sub _crossref_query_http_request {
  my ($user, $password, $query_xml) = @_;
  my $req = HTTP::Request->new(POST => CR_URL);
  $req->content_type('application/x-www-form-urlencoded');
  $req->content(join('&',
		     'usr='.$user,
		     'pwd='.$password,
		     'db=mddb',
		     'report=Brief',
		     'format=XSD_XML',
		     'qdata='.uri_escape($query_xml)));
  return $req;
}

sub crossref_query {
  my ($self, $doi) = @_;
  my $ua = $self->ua;
  my $response = $ua->request(_crossref_query_http_request($self->crossref_account, $self->build_query($doi)));
  $response->is_success or $self->errstr($response->status_line), return undef;
  return $response->decoded_content;
}

sub query_xml_template {
'<?xml version="1.0" encoding="UTF-8"?>
<query_batch version="2.0"
             xmlns="http://www.crossref.org/qschema/2.0"
             xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <head>
    <email_address>__EMAIL__</email_address>
    <doi_batch_id>DOI-B1</doi_batch_id>
  </head>
  <body>
    <query key="MyKey1" enable-multiple-hits="false" expanded-results="true">
      <doi>__DOI__</doi>
    </query>      
  </body>
</query_batch>
';
}

sub build_query {
  my ($self, $doi) = @_;
  my $xml         = $self->query_xml_template;
  my $email       = $self->bibliotech->siteemail;
  my $escaped_doi = encode_entities($doi);
  $xml =~ s/__EMAIL__/$email/;
  $xml =~ s/__DOI__/$escaped_doi/;
  return $xml;
}

sub crossref_account {
  my $self     = shift;
  my $user     = $self->cfg('CR_USER')     or return;
  my $password = $self->cfg('CR_PASSWORD') or return;
  return ($user, $password);
}

1;
__END__
