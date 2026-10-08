import gleam/option.{None, Some}
import gloss/s3/internal/xml

pub fn parses_an_s3_document_test() {
  let assert Ok(root) =
    xml.parse(<<
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!-- a listing -->
<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">
  <Name>bucket</Name>
  <Contents>
    <Key>a &amp; b &lt;1&gt; &#233; &#x41;</Key>
    <Size>12</Size>
  </Contents>
  <Contents><Key>  </Key><Size>0</Size></Contents>
  <Empty/>
  <Data><![CDATA[<raw> & text]]></Data>
</ListBucketResult>
":utf8,
    >>)
  assert root.name == "ListBucketResult"
  assert xml.child_text(root, "Name") == "bucket"
  let assert [first, second] = xml.children(root, "Contents")
  assert xml.child_text(first, "Key") == "a & b <1> é A"
  assert xml.child_text(first, "Size") == "12"
  // Whitespace that is an element's whole text is kept: keys can be spaces.
  assert xml.child_text(second, "Key") == "  "
  assert xml.child(root, "Empty") |> option.map(xml.text) == Some("")
  assert xml.child_text(root, "Data") == "<raw> & text"
  assert xml.child(root, "Missing") == None
  assert xml.optional_text(root, "Missing") == None
}

pub fn parses_an_error_document_test() {
  let assert Ok(root) =
    xml.parse(<<
      "<Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message><RequestId>4442587FB7D0A2F9</RequestId></Error>":utf8,
    >>)
  assert root.name == "Error"
  assert xml.child_text(root, "Code") == "NoSuchKey"
  assert xml.child_text(root, "RequestId") == "4442587FB7D0A2F9"
}

pub fn rejects_broken_documents_test() {
  let assert Error(_) = xml.parse(<<"":utf8>>)
  let assert Error(_) = xml.parse(<<"<a><b></a>":utf8>>)
  let assert Error(_) = xml.parse(<<"<a>text":utf8>>)
  let assert Error(_) = xml.parse(<<"<a>&nope;</a>":utf8>>)
  let assert Error(_) = xml.parse(<<"<a/><b/>":utf8>>)
}

pub fn attributes_are_skipped_test() {
  let assert Ok(root) =
    xml.parse(<<"<a x=\"1 > 2\" y='/>'><b>ok</b></a>":utf8>>)
  assert xml.child_text(root, "b") == "ok"
}

pub fn escape_test() {
  assert xml.escape("<a href=\"x\">&'</a>")
    == "&lt;a href=&quot;x&quot;&gt;&amp;&apos;&lt;/a&gt;"
}
