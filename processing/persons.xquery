import module namespace bod = "http://www.bodleian.ox.ac.uk/bdlss" at "lib/msdesc2solr.xquery";
declare namespace tei="http://www.tei-c.org/ns/1.0";
declare option saxon:output "indent=yes";

(: Read authority file :)
declare variable $authorityentries := doc("../authority/persons.xml")/tei:TEI/tei:text/tei:body/tei:listPerson/tei:person[@xml:id];
declare variable $worksauthority := doc("../authority/works.xml")/tei:TEI/tei:text/tei:body/tei:listBibl/tei:bibl[@xml:id];
declare variable $authorsinworksauthority := false();

(: Find instances in manuscript description files, building in-memory data structure, to avoid having to search across all files for each authority file entry :)
declare variable $allinstances :=
    for $instance in collection('../collections?select=*.xml;recurse=yes')//tei:msDesc//(tei:author|tei:editor|tei:persName[not(parent::tei:author or parent::tei:editor)])
        let $roottei := $instance/ancestor::tei:TEI
        let $shelfmark := ($roottei/tei:teiHeader/tei:fileDesc/tei:sourceDesc/tei:msDesc/tei:msIdentifier/tei:idno)[1]/string()
        let $roles := 
            if ($instance/self::tei:author) 
                then ('author') 
            else if ($instance/parent::tei:title)
                then ('Subject of a work', tokenize($instance/@role/data(), ' '))
            else tokenize($instance/@role/data(), ' ')
        let $datesoforigin := bod:summarizeDates($roottei//tei:origin//tei:origDate)
        let $placesoforigin := distinct-values($roottei//tei:origin//tei:origPlace/normalize-space()[string-length(.) gt 0])
        let $institution := $roottei//tei:msDesc/tei:msIdentifier/tei:institution/string()
        let $repository := $roottei//tei:msDesc/tei:msIdentifier/tei:repository[1]/string()
        return
        <instance>
            { for $key in tokenize($instance/@key, ' ') return <key>{ $key }</key> }
            <name>{ normalize-space($instance/string()) }</name>
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
            { for $role in $roles return <role>{ $role }</role> }
            {
            if ($authorsinworksauthority) then () else
                if (some $role in $roles satisfies $role = ('author','aut') and not($instance/parent::tei:bibl)) then 
                    for $workid in distinct-values($instance/ancestor::tei:msItem[tei:title/@key][1]/tei:title/@key/tokenize(data(), ' '))
                        return <authored>{ $workid }</authored>
                else if (some $role in $roles satisfies $role = ('translator','trl') and not($instance/parent::tei:bibl)) then 
                    for $workid in distinct-values($instance/ancestor::tei:msItem[tei:title/@key][1]/tei:title/@key/tokenize(data(), ' '))
                        return <translated>{ $workid }</translated>
                else
                    ()
            }
            {
            if (some $role in $roles satisfies $role eq 'Subject of a work' and not($instance/parent::tei:bibl)) then 
                for $workid in distinct-values($instance/../../tei:title[@key]/@key/tokenize(data(), ' '))
                    return <subjectof>{ $workid }</subjectof>
            else
                ()
            }
            <shelfmark>{ $shelfmark }</shelfmark>
        </instance>;

<add>
{
    comment{concat(' Indexing started at ', current-dateTime(), ' using authority file at ', substring-after(base-uri($authorityentries[1]), 'file:'), ' ')}
}
{
    (: Log instances with key attributes not in the authority file :)
    for $key in distinct-values($allinstances/key)
        return if (not(some $entryid in $authorityentries/@xml:id/data() satisfies $entryid eq $key)) then
            bod:logging('warn', 'Key attribute not found in authority file: will create broken link', ($key, $allinstances[@k = $key]/name))
        else
            ()
}
{
    (: Loop thru each entry in the authority file :)
    for $person in $authorityentries

        (: Get info in authority entry :)
        let $id := $person/@xml:id/data()
        let $name := if ($person/tei:persName[@type='display']) then normalize-space($person/tei:persName[@type='display'][1]/string()) else normalize-space($person/tei:persName[1]/string())
        let $variants := for $variant in $person/tei:persName[not(@type='display')] return normalize-space($variant/string())
        let $extrefs := for $ref in $person/tei:note[@type='links']//tei:item/tei:ref return concat($ref/@target/data(), '|', bod:lookupAuthorityName(normalize-space($ref/tei:title/string())))
        let $bibrefs := for $bibl in $person/tei:bibl return bod:italicizeTitles($bibl)
        let $notes := for $note in $person/tei:note[not(@type='links')] return bod:italicizeTitles($note)
        
        (: Get info in all the instances in the manuscript description files :)
        let $instances := $allinstances[key = $id]
        let $roles := distinct-values(for $role in distinct-values($instances/role/text()) return bod:personRoleLookup($role))
        let $isauthor := some $role in $instances/role/text() satisfies $role = ('author','aut')
        let $istranslator := some $role in $instances/role/text() satisfies $role = ('translator','trl')
        let $issubjectofawork := some $role in $instances/role/text() satisfies $role eq 'Subject of a work'

        (: Output a Solr doc element :)
        return if (count($instances) gt 0) then
            <doc>
                <field name="type">person</field>
                <field name="pk">{ $id }</field>
                <field name="id">{ $id }</field>
                <field name="title">{ $name }</field>
                <field name="alpha_title">{  bod:alphabetize($name) }</field>
                {
                (: Roles (e.g. author, translator, scribe, former owner, etc) :)
                if (count($roles) gt 0) then
                    for $role in $roles
                        order by $role
                        return <field name="pp_roles_sm">{ $role }</field>
                else
                    <field name="pp_roles_sm">Not specified</field>
                }
                {
                (: Alternative names :)
                for $variant in distinct-values($variants)
                    order by $variant
                    return <field name="pp_variant_sm">{ $variant }</field>
                }
                {
                let $lcvariants := for $variant in ($name, $variants) return lower-case($variant)
                for $instancevariant in distinct-values($instances/name/text())
                    order by $instancevariant
                    return if (not(lower-case($instancevariant) = $lcvariants)) then
                        <field name="pp_variant_sm">{ $instancevariant }</field>
                    else
                        ()
                }
                {
                (: Links to external authorities and other web sites :)
                for $extref in $extrefs
                    order by $extref
                    return <field name="link_external_smni">{ $extref }</field>
                }
                {
                (: Bibliographic references about the person :)
                for $bibref in $bibrefs
                    return <field name="bibref_smni">{ $bibref }</field>
                }
                {
                (: Notes about the person :)
                for $note in $notes
                    return <field name="note_smni">{ $note }</field>
                }
                {
                (: See also links to other entries in the same authority file :)
                let $relatedids := tokenize(translate(string-join(($person/@corresp, $person/@sameAs), ' '), '#', ''), ' ')
                for $relatedid in distinct-values($relatedids)
                    let $url := concat("/catalog/", $relatedid)
                    let $linktext := ($authorityentries[@xml:id = $relatedid]/tei:persName[@type = 'display'][1])[1]
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
                (: Links to works by this person (if they're an author) :)
                if ($isauthor) then 
                    let $workids :=
                        if ($authorsinworksauthority) then distinct-values($worksauthority[tei:author[not(@role)]/@key = $id]/@xml:id)
                        else distinct-values(($instances/authored/text(), $worksauthority[tei:author[not(@role)]/@key = $id]/@xml:id))
                    return 
                    for $workid in $workids
                        let $url := concat("/catalog/", $workid)
                        let $linktext := ($worksauthority[@xml:id = $workid]/tei:title[@type = 'uniform'][1])[1]
                        order by lower-case(bod:stripLeadingStopWords(($linktext, '')[1]))
                        return
                        if (exists($linktext)) then
                            let $link := concat($url, "|", normalize-space($linktext/string()))
                            return
                            <field name="link_works_smni">{ $link }</field>
                        else
                            bod:logging('info', 'Cannot create link from author to work', ($id, $workid))
                else
                    ()
                }
                {
                (: Links to works translated by this person (if any) :)
                if ($istranslator) then 
                    let $workids :=
                        if ($authorsinworksauthority)
                            then distinct-values($worksauthority[tei:author[@role='translator']/@key = $id]/@xml:id)
                            else distinct-values(($instances/translated/text(), $worksauthority[tei:author[@role='translator']/@key = $id]/@xml:id))
                    return 
                    for $workid in $workids
                        let $url := concat("/catalog/", $workid)
                        let $linktext := ($worksauthority[@xml:id = $workid]/tei:title[@type = 'uniform'][1])[1]
                        order by lower-case($linktext)
                        return
                        if (exists($linktext)) then
                            let $link := concat($url, "|", normalize-space($linktext/string()))
                            return
                            <field name="link_translations_smni">{ $link }</field>
                        else
                            bod:logging('info', 'Cannot create link from translator to work', ($id, $workid))
                else
                    ()
                }
                {
                (: Links to works this person is a subject of :)
                if ($issubjectofawork) then 
                    let $workids := distinct-values($instances/subjectof/text())
                    return 
                    for $workid in $workids
                        let $url := concat("/catalog/", $workid)
                        let $linktext := ($worksauthority[@xml:id = $workid]/tei:title[@type = 'uniform'][1])[1]
                        order by lower-case($linktext)
                        return
                        if (exists($linktext)) then
                            let $link := concat($url, "|", normalize-space($linktext/string()))
                            return
                            <field name="link_subjectofworks_smni">{ $link }</field>
                        else
                            bod:logging('info', 'Cannot create link from subject of work to the work', ($id, $workid))
                else
                    ()
                }
                {
                (: Shelfmarks (indexed in special non-tokenized field) :)
                for $shelfmark in bod:shelfmarkVariants(distinct-values($instances/shelfmark/text()))
                    order by $shelfmark
                    return
                    <field name="shelfmarks">{ $shelfmark }</field>
                }
                {
                (: Links to manuscripts containing mentions of the person :)
                for $link in distinct-values($instances/link/text())
                    order by lower-case(tokenize($link, '\|')[2])
                    return
                    <field name="link_manuscripts_smni">{ $link }</field>
                }
            </doc>
        else
            (
            bod:logging('info', 'Skipping unused authority file entry', ($id, $name))
            )
}
{
    (: Log instances without key attributes :)
    for $instancename in distinct-values($allinstances[not(key)]/name)
        order by $instancename
        return bod:logging('info', 'Person without key attribute', $instancename)
}
</add>