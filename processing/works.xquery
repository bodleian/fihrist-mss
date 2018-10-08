import module namespace bod = "http://www.bodleian.ox.ac.uk/bdlss" at "lib/msdesc2solr.xquery";
declare namespace tei="http://www.tei-c.org/ns/1.0";
declare option saxon:output "indent=yes";

(: Read authority file :)
declare variable $authorityentries := doc("../authority/works.xml")/tei:TEI/tei:text/tei:body/tei:listBibl/tei:bibl[@xml:id];
declare variable $authorsinworksauthority := false();
declare variable $personauthority := doc("../authority/persons.xml")/tei:TEI/tei:text/tei:body/tei:listPerson/tei:person[@xml:id];

(: Find instances in manuscript description files, building in-memory data 
   structure, to avoid having to search across all files for each authority file entry :)
declare variable $allinstances :=
    for $instance in collection('../collections?select=*.xml;recurse=yes')//tei:title[@key or not((parent::tei:msItem/@n and count(ancestor::tei:msItem) gt 1) or matches(., '(chapter|section|باب)', 'i'))]
        let $roottei := $instance/ancestor::tei:TEI
        let $shelfmark := ($roottei/tei:teiHeader/tei:fileDesc/tei:sourceDesc/tei:msDesc/tei:msIdentifier/tei:idno)[1]/string()
        let $datesoforigin := bod:summarizeDates($roottei//tei:origin//tei:origDate)
        let $placesoforigin := distinct-values($roottei//tei:origin//tei:origPlace/normalize-space()[string-length(.) gt 0])
        let $langcodes := tokenize(string-join($instance/ancestor::*[tei:textLang][1]/tei:textLang/(@mainLang|@otherLangs), ' '), ' ')
        let $institution := $roottei//tei:msDesc/tei:msIdentifier/tei:institution/string()
        let $repository := $roottei//tei:msDesc/tei:msIdentifier/tei:repository[1]/string()
        return
        <instance>
            { for $key in tokenize($instance/@key, ' ') return <key>{ $key }</key> }
            <title>{ normalize-space($instance/string()) }</title>
            <link>{ concat(
                        '/catalog/', 
                        $roottei/@xml:id/data(), 
                        '|', 
                        $shelfmark,
                        ' (', 
                        $repository,
                        if ($repository ne $institution) then concat(', ', translate(replace($institution, ' \(', ', '), ')', ''), ')') else ')',
                        '|',
                        if ($roottei//tei:msPart) then 'Composite manuscript' else string-join(($datesoforigin, $placesoforigin)[string-length() gt 0], '; ')
                    )
            }</link>
            {
            if ($authorsinworksauthority) then () else 
                for $authorid in ($instance/ancestor::tei:msItem[tei:author][1]/tei:author/@key/data(), $instance/parent::*/(tei:author|tei:persName[@role=('author','aut')])/@key/data())
                    return <author>{ $authorid }</author>
                ,
                for $translatorid in $instance/parent::*//*[@role=('trl','translator','Translator')]/@key/data()
                    return <translator>{ $translatorid }</translator>
            }
            {
            for $subjectid in $instance/parent::tei:msItem/tei:title//tei:persName/@key/data()
                return <personintitle>{ $subjectid }</personintitle>
            }
            { for $instanceid in $instance/parent::tei:msItem/@xml:id return <instanceid>{ $instanceid }</instanceid> }
            <shelfmark>{ $shelfmark }</shelfmark>
            <institution>{ $institution }</institution>
            { for $langcode in $langcodes return <lang>{ $langcode }</lang> }
        </instance>;

<add>
{
    comment{concat(' Indexing started at ', current-dateTime(), ' using authority file at ', substring-after(base-uri($authorityentries[1]), 'file:'), ' ')}
}
{
    (: Log instances with key attributes not in the authority file :)
    for $key in distinct-values($allinstances/key)
        return if (not(some $entryid in $authorityentries/@xml:id/data() satisfies $entryid eq $key)) then
            bod:logging('warn', 'Key attribute not found in authority file: will create broken link', ($key, $allinstances[key = $key]/title))
        else
            ()
}
{
    (: Loop thru each entry in the authority file :)
    for $work in $authorityentries

        (: Get info in authority entry :)
        let $id := $work/@xml:id/data()
        let $title := if ($work/tei:title[@type='uniform']) then normalize-space($work/tei:title[@type='uniform'][1]/string()) else normalize-space($work/tei:title[1]/string())
        let $variants := for $v in $work/tei:title[not(@type='uniform')] return normalize-space($v/string())
        let $extrefs := for $r in $work/tei:note[@type='links']//tei:item/tei:ref return concat($r/@target/data(), '|', bod:lookupAuthorityName(normalize-space($r/tei:title/string())))
        let $bibrefs := for $b in $work/tei:bibl return bod:italicizeTitles($b)
        let $notes := for $n in $work/tei:note[not(@type=('links','shelfmark','language','subject'))] return bod:italicizeTitles($n)
        let $subjects := distinct-values($work/tei:note[@type='subject']/string())
        (: let $lang := $work/tei:textLang :)
        
        (: Get info in all the instances in the manuscript description files :)
        let $instances := $allinstances[key = $id]

        (: Output a Solr doc element :)
        return if (count($instances) gt 0) then
            <doc>
                <field name="type">work</field>
                <field name="pk">{ $id }</field>
                <field name="id">{ $id }</field>
                <field name="title">{ $title }</field>
                <field name="alpha_title">
                    { 
                    if (contains($title, ':')) then
                        bod:alphabetize($title)
                    else
                        bod:alphabetizeTitle($title)
                    }
                </field>
                {
                (: Alternative titles :)
                for $variant in distinct-values($variants)
                    order by $variant
                    return <field name="wk_variant_sm">{ $variant }</field>
                }
                {
                let $lcvariants := for $variant in ($title, $variants) return lower-case($variant)
                for $instancevariant in distinct-values($instances/title/text())
                    order by $instancevariant
                    return if (not(lower-case($instancevariant) = $lcvariants)) then
                        <field name="wk_variant_sm">{ $instancevariant }</field>
                    else
                        ()
                }
                {
                for $institution in distinct-values($instances/institution/text())
                    order by $institution
                    return <field name="institution_sm">{ $institution }</field>
                }
                {
                (: Links to external authorities and other web sites :)
                for $extref in $extrefs
                    order by $extref
                    return <field name="link_external_smni">{ $extref }</field>
                }
                {
                (: Bibliographic references about the work :)
                for $bibref in $bibrefs
                    return <field name="bibref_smni">{ $bibref }</field>
                }
                {
                (: Notes about the work :)
                for $note in $notes
                    return <field name="note_smni">{ $note }</field>
                }
                {
                (: Languages in the authority file (so far only Medieval does this)
                bod:languages($work/tei:textLang, 'lang_sm')
                :)
                ()
                }
                {
                (: Languages in TEI files :)
                for $langcode in distinct-values($instances/lang/text())
                    return <field name="lang_sm">{ bod:languageCodeLookup($langcode) }</field>
                }
                {
                (: Subjects (Medieval only)
                for $subject in $subjects
                    return <field name="wk_subjects_sm">{ normalize-space($subject) }</field>
                :)
                ()
                }
                {
                (: See also links to other entries in the same authority file :)
                let $relatedids := tokenize(translate(string-join(($work/@corresp, $work/@sameAs), ' '), '#', ''), ' ')
                for $relatedid in distinct-values($relatedids)
                    let $url := concat("/catalog/", $relatedid)
                    let $linktext := ($authorityentries[@xml:id = $relatedid]/tei:title[@type = 'uniform'][1])[1]
                    order by lower-case($linktext)
                    return
                    if (exists($linktext) and $allinstances[key = $relatedid]) then
                        let $link := concat($url, "|", normalize-space($linktext/string()))
                        return
                        <field name="link_related_smni">{ $link }</field>
                    else
                        bod:logging('info', 'Cannot create see-also link', ($id, $relatedid))
                }
                {
                (: Links to the authors of the work :)
                let $authorids := 
                    if ($authorsinworksauthority) then distinct-values($work/tei:author[not(@role)]/@key/data())
                    else distinct-values(($instances/author/text(), $work/tei:author[not(@role)]/@key/data()))
                for $authorid in $authorids
                    let $url := concat("/catalog/", $authorid)
                    let $linktext := ($personauthority[@xml:id = $authorid]/tei:persName[@type = 'display'][1])[1]
                    order by lower-case($linktext)
                    return
                    if (exists($linktext)) then
                        let $link := concat($url, "|", normalize-space($linktext/string()))
                        return
                        <field name="link_author_smni">{ $link }</field>
                    else
                        bod:logging('info', 'Cannot create link from work to author', ($id, $authorid))
                }
                {
                (: Links to the translators of the work :)
                let $translatorids := 
                    if ($authorsinworksauthority) then distinct-values($work/tei:author[@role=('translator','trl')]/@key/data())
                    else distinct-values(($instances/translator/text(), $work/tei:author[@role=('translator','trl')]/@key/data()))
                for $translatorid in $translatorids
                    let $url := concat("/catalog/", $translatorid)
                    let $linktext := ($personauthority[@xml:id = $translatorid]/tei:persName[@type = 'display'][1])[1]
                    order by lower-case($linktext)
                    return
                    if (exists($linktext)) then
                        let $link := concat($url, "|", normalize-space($linktext/string()))
                        return
                        <field name="link_translator_smni">{ $link }</field>
                    else
                        bod:logging('info', 'Cannot create link from work to translator', ($id, $translatorid))
                }
                {
                (: Links to people who are subjects of the work (based on their name being tagged inside the title) :)
                let $subjectids := distinct-values($instances/personintitle/text())
                for $subjectid in $subjectids
                    let $url := concat("/catalog/", $subjectid)
                    let $linktext := ($personauthority[@xml:id = $subjectid]/tei:persName[@type = 'display'][1])[1]
                    order by lower-case($linktext)
                    return
                    if (exists($linktext)) then
                        let $link := concat($url, "|", normalize-space($linktext/string()))
                        return
                        <field name="link_subject_smni">{ $link }</field>
                    else
                        bod:logging('info', 'Cannot create link from work to subject of the work', ($id, $subjectid))
                }
                {
                (: Shelfmarks (indexed in special non-tokenized field) :)
                for $shelfmark in bod:shelfmarkVariants(distinct-values($instances/shelfmark/text()))
                    order by $shelfmark
                    return
                    <field name="shelfmarks">{ $shelfmark }</field>
                }
                {
                (: Links to manuscripts containing the work :)
                for $link in distinct-values($instances/link/text())
                    order by lower-case(tokenize($link, '\|')[2])
                    return
                    <field name="link_manuscripts_smni">{ $link }</field>
                }
            </doc>
        else
            (
            bod:logging('info', 'Skipping unused authority file entry', ($id, $title))
            )
}
{
    (: Log instances without key attributes :)
    for $instancetitle in distinct-values($allinstances[not(key) and instanceid]/title)
        order by $instancetitle
        return bod:logging('info', 'Work title without key attribute', $instancetitle)
}
</add>