/* Modifications for HTML parser support:
 * Copyright (c) 2011 Simon Grätzer simon@graetzer.org
 *
 * Copyright (c) 2008 Google Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation

#if canImport(libxml2)
import libxml2
#elseif canImport(libxml)
import libxml
#endif

private let kGDataXMLXPathDefaultNamespacePrefix = "_def_ns".cString(using: .utf8)
private let GDATAXMLNODE_DEFINE_GLOBALS = 1
private let kGDataXMLParseOptions = Int32(XML_PARSE_NOCDATA.rawValue | XML_PARSE_NOBLANKS.rawValue)
private let kGDataHTMLParseOptions = Int32(HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NOERROR.rawValue)
private let kGDataXMLParseRecoverOptions = Int32(XML_PARSE_NOCDATA.rawValue)
        | Int32(XML_PARSE_NOBLANKS.rawValue)
        | Int32(XML_PARSE_RECOVER.rawValue)

public class XmlCharKey: Hashable, Equatable, CustomStringConvertible, NSCopying {

    private let key: UnsafeMutablePointer<xmlChar>

    fileprivate init(xmlChar: UnsafePointer<xmlChar>) {
        self.key = xmlStrdup(xmlChar)
    }

    deinit {
        xmlFree(self.key)
    }

    // MARK: Hashable
    public func hash(into hasher: inout Hasher) {
        var chars: UnsafeMutablePointer<xmlChar>? = key

        while let pointee = chars?.pointee, pointee != 0 {
            hasher.combine(pointee)
            chars = chars?.successor()
        }
    }

    // MARK: Equatable
    public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? XmlCharKey else {
            return false
        }

        // compare the key strings
        if self.key == other.key { return true }

        let result = xmlStrcmp(self.key, other.key)
        return result == 0
    }

    public static func == (lhs: XmlCharKey, rhs: XmlCharKey) -> Bool {
        return lhs.isEqual(rhs)
    }

    // MARK: CustomStringConvertible
    public var description: String {
        return String.decodeCString(self.key, as: UTF8.self, repairingInvalidCodeUnits: true)?.result ?? ""
    }

    // MARK: NSCopying
    public func copy(with zone: NSZone? = nil) -> Any {
        return XmlCharKey(xmlChar: self.key)
    }

}

/**
 * xmlXPathNodeSetIsEmpty:
 * @ns: a node-set
 *
 * Checks whether @ns is empty or not.
 *
 * Returns %TRUE if @ns is an empty node-set.
 */
private func xmlXPathNodeSetIsEmpty(_ ns: xmlNodeSetPtr?) -> Bool {
    return ns == nil || ns!.pointee.nodeNr == 0 || ns!.pointee.nodeTab == nil
}

public enum GDataXMLNodeKind: Int {
    case invalidKind = 0
    case documentKind
    case elementKind
    case attributeKind
    case namespaceKind
    case processingInstructionKind
    case commentKind
    case textKind
    case DTDKind
    case entityDeclarationKind
    case attributeDeclarationKind
    case elementDeclarationKind
    case notationDeclarationKind
}

// isEqual: has the fatal flaw that it doesn't deal well with the received
// being nil. We'll use this utility instead.

// Static copy of AreEqualOrBothNil from GDataObject.m, so that using
// GDataXMLNode does not require pulling in all of GData.
private func areEqualOrBothNilPrivate<T: Hashable>(obj1: T?, obj2: T?) -> Bool {
    if obj1 == nil && obj2 == nil {
        return true
    }
    return obj1 == obj2
}

// Make a fake qualified name we use as local name internally in libxml
// data structures when there's no actual namespace node available to point to
// from an element or attribute node
//
// Returns an autoreleased NSString*

private func GDataFakeQNameFor(URI: String?, name: String?) -> String {
    let localName = GDataXMLNode.localName(forName: name)
    // Try to copy objc behaviour
    let fakeQName = "{\(URI ?? "(null)")}:\(localName ?? "(null)")"
    return fakeQName
}

// libxml2 offers xmlSplitQName2, but that searches forwards. Since we may
// be searching for a whole URI shoved in as a prefix, like
//   {http://foo}:name
// we'll search for the prefix in backwards from the end of the qualified name
//
// returns a copy of qname as the local name if there's no prefix
private func splitQNameReverse(_ qname: UnsafePointer<xmlChar>) -> (qname: UnsafeMutablePointer<xmlChar>?,
                                                                    prefix: UnsafeMutablePointer<xmlChar>?) {
    var prefix: UnsafeMutablePointer<xmlChar>?
    // search backwards for a colon
    let qnameLen = xmlStrlen(qname)
    for idx in (0...qnameLen - 1).reversed() {

        if qname.advanced(by: Int(idx)).pointee == /*':'*/0x003a {
            // found the prefix; copy the prefix
            if idx > 0 {
                prefix = xmlStrsub(qname, 0, idx)
            }
            else {
                prefix = nil
            }

            if idx < qnameLen - 1 {
                // return a copy of the local name
                let localName = xmlStrsub(qname, idx + 1, qnameLen - idx - 1)
                return (localName, prefix)
            }
            else {
                return (nil, nil)
            }
        }
    }

    // no colon found, so the qualified name is the local name
    let qnameCopy = xmlStrdup(qname)
    return (qnameCopy, nil)
}

private func registerNamespaces(_ ns: [String: String]?, _ xpathCtx: xmlXPathContextPtr, _ nsNodePtr: xmlNodePtr?) {
    // if a namespace dictionary was provided, register its contents
    if let namespaces = ns {
        // the dictionary keys are prefixes; the values are URIs
        for  (prefix, uri) in namespaces {
            let result = xmlXPathRegisterNs(xpathCtx, prefix, uri)

            assert(result == 0, "GDataXMLNode XPath namespace \(prefix) issue")
        }
    }
    else {
        // no namespace dictionary was provided
        // register the namespaces of this node step through the namespaces,
        // if any, and register each with the xpath context
        if nsNodePtr != nil {
            var nsPtr = nsNodePtr!.pointee.ns
            while nsPtr != nil {

                // default namespace is nil in the tree, but there's no way to
                // register a default namespace, so we'll register a fake one,
                // _def_ns
                var prefix = nsPtr!.pointee.prefix

                kGDataXMLXPathDefaultNamespacePrefix?.withUnsafeBytes({
                    if prefix == nil {
                        prefix = $0.baseAddress?.assumingMemoryBound(to: UInt8.self)
                    }

                    let result = xmlXPathRegisterNs(xpathCtx, prefix, nsPtr!.pointee.href)
                    assert(result == 0, "GDataXMLNode XPath namespace \(prefix.map { String(cString: $0) } ?? "") issue")
                })

                nsPtr = nsPtr!.pointee.next
            }
        }
    }
}

public class GDataXMLNode: Hashable, NSCopying {

    // NSXMLNodes can have a namespace URI or prefix even if not part
    // of a tree; xmlNodes cannot.  When we create nodes apart from
    // a tree, we'll store the dangling prefix or URI in the xmlNode's name,
    // like
    //   "prefix:name"
    // or
    //   "{http://uri}:name"
    //
    // We will fix up the node's namespace and name (and those of any children)
    // later when adding the node to a tree with addChild: or addAttribute:.
    // See fixUpNamespacesForNode:.

    public var xmlNode_: xmlNodePtr?; // may also be an xmlAttrPtr or xmlNsPtr
    public var shouldFreeXMLNode_: Bool; // if yes, xmlNode_ will be free'd in dealloc

    // cached values
    var cachedName_: String?
    var cachedChildren_: [GDataXMLNode]?
    var cachedAttributes_: [GDataXMLNode]?

    // Druk. Call this method on start
    public class func load() {
        xmlInitParser()
    }

    // Note on convenience methods for making stand-alone element and
    // attribute nodes:
    //
    // Since we're making a node from scratch, we don't
    // have any namespace info.  So the namespace prefix, if
    // any, will just be slammed into the node name.
    // We'll rely on the -addChild method below to remove
    // the namespace prefix and replace it with a proper ns
    // pointer.

    public static func element(withName name: String) -> GDataXMLNode? {
        if let theNewNode = xmlNewNode(nil, name) {
            // succeeded
            return nodeConsuming(xmlNode: theNewNode)
        }
        return nil
    }

    public static func element(withName name: String, stringValue: String) -> GDataXMLNode? {
        if let theNewNode = xmlNewNode(nil, name) {
            if let textNode = xmlNewText(stringValue) {
                if xmlAddChild(theNewNode, textNode) != nil {
                    // succeeded
                    return nodeConsuming(xmlNode: theNewNode)
                }
            }

            // failed; free the node and any children
            xmlFreeNode(theNewNode)
        }
        return nil
    }

    public static func element(withName name: String, theURI: String) -> GDataXMLNode? {
        // since we don't know a prefix yet, shove in the whole URI; we'll look for
        // a proper namespace ptr later when addChild calls fixUpNamespacesForNode

        let fakeQName = GDataFakeQNameFor(URI: theURI, name: name)

        if let theNewNode = xmlNewNode(nil, fakeQName) {
            return nodeConsuming(xmlNode: theNewNode)
        }
        return nil
    }

    public static func attribute(withName name: String, stringValue value: String) -> GDataXMLNode? {

        if let theNewAttr = xmlNewProp(nil, name, value) {
            return theNewAttr.withMemoryRebound(to: xmlNode.self, capacity: 1, { node in
                nodeConsuming(xmlNode: node)
            })
        }
        return nil
    }

    public static func attribute(withName name: String, URI: String, value: String) -> GDataXMLNode? {
        // since we don't know a prefix yet, shove in the whole URI; we'll look for
        // a proper namespace ptr later when addChild calls fixUpNamespacesForNode
        let fakeQName = GDataFakeQNameFor(URI: URI, name: name)

        if let theNewAttr = xmlNewProp(nil, fakeQName, value) {
            return theNewAttr.withMemoryRebound(to: xmlNode.self, capacity: 1, { node in
                nodeConsuming(xmlNode: node)
            })
        }

        return nil
    }

    public static func textWithStringValue(value: String) -> GDataXMLNode? {
        if let theNewText = xmlNewText(value) {
            return nodeConsuming(xmlNode: theNewText)
        }
        return nil
    }

    public static func namespace(withName name: String?, stringValue value: String) -> GDataXMLNode? {
        if name != nil && name!.count > 0 {
            if let theNewNs = xmlNewNs(nil, value, name) {
                return theNewNs.withMemoryRebound(to: xmlNode.self, capacity: 1, { node in
                    nodeConsuming(xmlNode: node)
                })
            }
            return nil
        }
        if let theNewNs = xmlNewNs(nil, value, nil) {
            return theNewNs.withMemoryRebound(to: xmlNode.self, capacity: 1, { node in
                nodeConsuming(xmlNode: node)
            })
        }
        return nil
    }

    public static func nodeConsuming(xmlNode: xmlNodePtr) -> GDataXMLNode {
        if xmlNode.pointee.type == XML_ELEMENT_NODE {
            return GDataXMLElement(consumingXMLNode: xmlNode)
        }
        else {
            return GDataXMLNode(consumingXMLNode: xmlNode)
        }
    }

    public init(xmlNode: xmlNodePtr?, shouldFreeXMLNode: Bool) {
        xmlNode_ = xmlNode
        shouldFreeXMLNode_ = shouldFreeXMLNode
    }

    public convenience init(consumingXMLNode theXMLNode: xmlNodePtr) {
        self.init(xmlNode: theXMLNode, shouldFreeXMLNode: true)
    }

    public static func nodeBorrowing(xmlNode: xmlNodePtr) -> GDataXMLNode {
        if xmlNode.pointee.type == XML_ELEMENT_NODE {
            return GDataXMLElement(borrowingXMLNode: xmlNode)
        }
        else {
            return GDataXMLNode(borrowingXMLNode: xmlNode)
        }
    }

    public convenience init(borrowingXMLNode theXMLNode: xmlNodePtr) {
        self.init(xmlNode: theXMLNode, shouldFreeXMLNode: false)
    }

    public func releaseCachedValues() {
        cachedName_ = nil
        cachedChildren_ = nil
        cachedAttributes_ = nil
    }

    // convert xmlChar* to NSString*
    //
    // returns an autoreleased NSString*, from the current node's document strings
    // cache if possible
    public func stringFrom(xmlString chars: UnsafePointer<xmlChar>?) -> String? {

        // assert(chars != nil, "GDataXMLNode sees an unexpected empty string");
        if chars == nil {
            return nil
        }
        var cacheDict: [XmlCharKey: String]?
        var result: String?

        if let safeXmlNode = xmlNode_, safeXmlNode.pointee.type == XML_ELEMENT_NODE
                                        || safeXmlNode.pointee.type == XML_ATTRIBUTE_NODE
                                        || safeXmlNode.pointee.type == XML_TEXT_NODE {
            // there is no xmlDocPtr in XML_NAMESPACE_DECL nodes,
            // so we can't cache the text of those

            // look for a strings cache in the document
            //
            // the cache is in the document's user-defined _private field

            if safeXmlNode.pointee.doc != nil {
                if let tempCacheDict = safeXmlNode.pointee.doc.pointee._private {
                    cacheDict = tempCacheDict.assumingMemoryBound(to: Dictionary<XmlCharKey, String>.self).pointee

                    // this document has a strings cache
                    if let result = cacheDict![XmlCharKey(xmlChar: chars!)] {
                        // we found the xmlChar string in the cache; return the previously
                        // allocated NSString, rather than allocate a new one
                        return result
                    }
                }
            }
        }

        // allocate a new NSString for this xmlChar*
        result = String.decodeCString(chars, as: UTF8.self, repairingInvalidCodeUnits: true)?.result
        if cacheDict != nil {
            // save the string in the document's string cache
            cacheDict![XmlCharKey(xmlChar: chars!)] = result
        }

        return result
    }

    deinit {
        if xmlNode_ != nil && shouldFreeXMLNode_ {
            xmlFreeNode(xmlNode_)
            xmlNode_ = nil
        }

        releaseCachedValues()
    }

    // MARK: -

    public func setStringValue(str: String?) {
        if let safeXmlNode = xmlNode_, str != nil {
            if safeXmlNode.pointee.type == XML_NAMESPACE_DECL {
                // for a namespace node, the value is the namespace URI
                safeXmlNode.withMemoryRebound(to: xmlNs.self, capacity: 1, { nsNode in
                    if nsNode.pointee.href != nil {
                        xmlFree(UnsafeMutablePointer<xmlChar>(mutating: nsNode.pointee.href))
                    }
                    nsNode.pointee.href = UnsafePointer<xmlChar>(xmlStrdup(str))
                })
            }
            else {

                // attribute or element node

                // do we need to call xmlEncodeSpecialChars?
                xmlNodeSetContent(xmlNode_, str)
            }
        }
    }

    public func stringValue() -> String? {
        var str: String?
        if let safeXmlNode = xmlNode_ {
            if safeXmlNode.pointee.type == XML_NAMESPACE_DECL {
                // for a namespace node, the value is the namespace URI
                safeXmlNode.withMemoryRebound(to: xmlNs.self, capacity: 1, { nsNode in
                    str = self.stringFrom(xmlString: nsNode.pointee.href)
                })
            }
            else {
                // attribute or element node
                if let chars = xmlNodeGetContent(xmlNode_) {
                    str = self.stringFrom(xmlString: chars)
                    xmlFree(chars)
                }
            }
        }
        return str
    }

    public func xmlString() -> String? {
        var str: String?
        if xmlNode_ != nil {
            if let buff = xmlBufferCreate() {
                let doc: xmlDocPtr? = nil
                let level: Int32 = 0
                let format: Int32 = 1
                let result = xmlNodeDump(buff, doc, xmlNode_, level, format)
                if result > -1 {
                    let data = Data(bytes: xmlBufferContent(buff), count: Int(xmlBufferLength(buff)))
                    str = String(data: data, encoding: String.Encoding.utf8)
                }
                xmlBufferFree(buff)
            }
        }

        // remove leading and trailing whitespace
        return str?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    public func localName() -> String? {
        var str: String?
        if let safeXmlNode = xmlNode_ {
            str = self.stringFrom(xmlString: safeXmlNode.pointee.name)
            // if this is part of a detached subtree, str may have a prefix in it
            str = GDataXMLNode.localName(forName: str)
        }
        return str
    }

    public func prefix() -> String? {
        var str: String?
        if let safeXmlNode = xmlNode_ {
            // the default namespace's prefix is an empty string, though libxml
            // represents it as NULL for ns->prefix
            str = ""

            if safeXmlNode.pointee.ns != nil && safeXmlNode.pointee.ns.pointee.prefix != nil {
                str = self.stringFrom(xmlString: safeXmlNode.pointee.ns.pointee.prefix)
            }
        }
        return str
    }

    public func URI() -> String? {
        var str: String?
        if let safeXmlNode = xmlNode_ {
            if safeXmlNode.pointee.ns != nil && safeXmlNode.pointee.ns.pointee.href != nil {
                str = self.stringFrom(xmlString: safeXmlNode.pointee.ns.pointee.href)
            }
        }
        return str
    }

    public func qualifiedName() -> String? {
        // internal utility
        var str: String?
        if let xmlNode = xmlNode_ {
            if xmlNode.pointee.type == XML_NAMESPACE_DECL {
                // name of a namespace node
                xmlNode.withMemoryRebound(to: xmlNs.self, capacity: 1, { nsNode in
                    // null is the default namespace; one is the loneliest number
                    if nsNode.pointee.prefix == nil {
                        str = ""
                    }
                    else {
                        str = self.stringFrom(xmlString: nsNode.pointee.prefix)
                    }
                })
            }
            else if xmlNode.pointee.ns != nil, let prefix = xmlNode.pointee.ns.pointee.prefix {
                // name of a non-namespace node
                // has a prefix
                withVaList([prefix, xmlNode.pointee.name]) { vaList in
                    var qname: UnsafeMutablePointer<CChar>?
                    if vasprintf(&qname, "%s:%s", vaList) >= 0 {
                        if let qname = qname {
                            str = String(cString: qname)
                        }
                        free(qname)
                    }
                }
            }
            else {
                // lacks a prefix
                str = self.stringFrom(xmlString: xmlNode.pointee.name)
            }
        }

        return str
    }

    public func name() -> String? {
        if cachedName_ != nil {
            return cachedName_
        }
        let str = self.qualifiedName()
        cachedName_ = str
        return str
    }

    public static func localName(forName name: String?) -> String? {
        if let name_ = name {
            if let range = name_.range(of: ":") {
                // found a colon
                let nextCharacter = name_.index(after: range.lowerBound)
                if nextCharacter < name_.endIndex {
                    let localName = name_[nextCharacter...]
                    return String(localName)
                }
            }
        }
        return name
    }

    public static func prefix(forName name: String?) -> String? {
        if let name_ = name {
            if let range = name_.range(of: ":") {
                let prefix = name_[..<range.lowerBound]
                return String(prefix)
            }
        }
        return nil
    }

    public func childCount() -> Int {
        if cachedChildren_ != nil {
            return cachedChildren_!.count
        }

        if xmlNode_ != nil {
            var count = 0
            var currChild = xmlNode_!.pointee.children
            while currChild != nil {
                count += 1
                currChild = currChild!.pointee.next
            }
            return count
        }
        return 0
    }

    public func children() -> [GDataXMLNode]? {
        if cachedChildren_ != nil {
            return cachedChildren_
        }
        var array: [GDataXMLNode]?
        if xmlNode_ != nil {
            var currChild = xmlNode_!.pointee.children

            while currChild != nil {
                let node = GDataXMLNode.nodeBorrowing(xmlNode: currChild!)
                if array == nil {
                    array = [node]
                }
                else {
                    array!.append(node)
                }
                currChild = currChild!.pointee.next
            }
            cachedChildren_ = array
        }
        return array
    }

    public func childAtIndex(index: Int) -> GDataXMLNode? {
        if let children = self.children() {
            if children.count > index {
                return children[index]
            }
        }
        return nil
    }

    public func kind() -> GDataXMLNodeKind {
        if xmlNode_ != nil {
            let nodeType = xmlNode_!.pointee.type
            switch nodeType {
            case XML_ELEMENT_NODE:          return .elementKind
            case XML_ATTRIBUTE_NODE:        return .attributeKind
            case XML_TEXT_NODE:             return .textKind
            case XML_CDATA_SECTION_NODE:    return .textKind
            case XML_ENTITY_REF_NODE:       return .entityDeclarationKind
            case XML_ENTITY_NODE:           return .entityDeclarationKind
            case XML_PI_NODE:               return .processingInstructionKind
            case XML_COMMENT_NODE:          return .commentKind
            case XML_DOCUMENT_NODE:         return .documentKind
            case XML_DOCUMENT_TYPE_NODE:    return .documentKind
            case XML_DOCUMENT_FRAG_NODE:    return .documentKind
            case XML_NOTATION_NODE:         return .notationDeclarationKind
            case XML_HTML_DOCUMENT_NODE:    return .documentKind
            case XML_DTD_NODE:              return .DTDKind
            case XML_ELEMENT_DECL:          return .elementDeclarationKind
            case XML_ATTRIBUTE_DECL:        return .attributeDeclarationKind
            case XML_ENTITY_DECL:           return .entityDeclarationKind
            case XML_NAMESPACE_DECL:        return .namespaceKind
            case XML_XINCLUDE_START:        return .processingInstructionKind
            case XML_XINCLUDE_END:          return .processingInstructionKind
            case XML_DOCB_DOCUMENT_NODE:    return .documentKind
            default:                        return .invalidKind
            }
        }
        return .invalidKind
    }

    public func firstNode(forXPath xpath: String) throws -> GDataXMLNode? {
        return try nodes(forXPath: xpath).first
    }

    public func nodes(forXPath xpath: String) throws -> [GDataXMLNode] {
        // call through with no explicit namespace dictionary; that will register the
        // root node's namespaces
        return try nodes(forXPath: xpath, namespaces: nil)
    }

    public func firstNode(forXPath xpath: String, namespaces: [String: String]) throws -> GDataXMLNode? {
        return try nodes(forXPath: xpath, namespaces: namespaces).first
    }

    public func nodes(forXPath xpath: String, namespaces: [String: String]?) throws -> [GDataXMLNode] {
        var array: [GDataXMLNode]?
        var errorCode = -1
        var errorInfo: [String: String]?

        // xmlXPathNewContext requires a doc for its context, but if our elements
        // are created from GDataXMLElement's initWithXMLString there may not be
        // a document. (We may later decide that we want to stuff the doc used
        // there into a GDataXMLDocument and retain it, but we don't do that now.)
        //
        // We'll temporarily make a document to use for the xpath context.

        var tempDoc: xmlDocPtr?
        var topParent: xmlNodePtr?

        if xmlNode_?.pointee.doc == nil {
            tempDoc = xmlNewDoc(nil)
            if tempDoc != nil {
                // find the topmost node of the current tree to make the root of
                // our temporary document
                topParent = xmlNode_
                while topParent?.pointee.parent != nil {
                    topParent = topParent?.pointee.parent
                }
                xmlDocSetRootElement(tempDoc, topParent)
            }
        }

        if let safeXmlNode = xmlNode_, safeXmlNode.pointee.doc != nil {
            if let xpathCtx = xmlXPathNewContext(safeXmlNode.pointee.doc) {
                // anchor at our current node
                xpathCtx.pointee.node = xmlNode_
                registerNamespaces(namespaces, xpathCtx, xmlNode_)

                // now evaluate the path
                if let xpathObj = xmlXPathEval(xpath, xpathCtx) {

                    // we have some result from the search
                    array = [GDataXMLNode]()

                    if let nodeSet = xpathObj.pointee.nodesetval {

                        // add each node in the result set to our array
                        var index: Int32 = 0
                        while index < nodeSet.pointee.nodeNr {
                            if let currNode = nodeSet.pointee.nodeTab.advanced(by: Int(index)).pointee {
                                let node = GDataXMLNode.nodeBorrowing(xmlNode: currNode)
                                array?.append(node)
                            }
                            index += 1
                        }
                    }
                    xmlXPathFreeObject(xpathObj)
                }
                else {
                    // provide an error for failed evaluation
                    errorCode = Int(xpathCtx.pointee.lastError.code)
                    if let msg = xpathCtx.pointee.lastError.str1 {
                        let errStr = String(cString: msg)
                        errorInfo = ["error": errStr]
                    }
                }

                xmlXPathFreeContext(xpathCtx)
            }
        }
        else {
            // not a valid node for using XPath
            errorInfo = ["error": "invalid node"]
        }

        if let array = array {
            if tempDoc != nil {
                xmlUnlinkNode(topParent)
                xmlSetTreeDoc(topParent, nil)
                xmlFreeDoc(tempDoc)
            }
            return array
        }
        else {
            throw NSError(domain: "com.google.GDataXML", code: errorCode, userInfo: errorInfo)
        }
    }

    public var description: String? {
        let nodeType = xmlNode_ != nil ? Int(xmlNode_!.pointee.type.rawValue) : -1
        // TODO: add class and memory address
        return "{type:\(nodeType) name:\(String(describing: self.name()))xml:\"\(String(describing: self.xmlString()))\"}"
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        if let nodeCopy = self.XMLNodeCopy() {
            return GDataXMLNode(consumingXMLNode: nodeCopy)
        }
        return GDataXMLNode(xmlNode: nil, shouldFreeXMLNode: false)
    }

    public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? GDataXMLNode else {
            return false
        }

        if self === other { return true; }

        return self.XMLNode() == other.XMLNode()
            || kind() == other.kind()
                && areEqualOrBothNilPrivate(obj1: self.name(), obj2: other.name())
                && self.children()?.count == other.children()?.count
    }

    public static func == (lhs: GDataXMLNode, rhs: GDataXMLNode) -> Bool {
        return lhs.isEqual(rhs)
    }

    public func hash(into hasher: inout Hasher) {
        if let xmlNode = xmlNode_, xmlStrlen(xmlNode.pointee.name) >= 4 {
            return xmlNode.pointee.name.withMemoryRebound(to: UInt32.self, capacity: 1) { hash in
                hasher.combine(Int(hash.pointee))
            }
        }
    }

    internal func XMLNodeCopy() -> xmlNodePtr? {
        if xmlNode_ != nil {

            // Note: libxml will create a new copy of namespace nodes (xmlNs records)
            // and attach them to this copy in order to keep namespaces within this
            // node subtree copy value.

            let nodeCopy = xmlCopyNode(xmlNode_!, 1); // 1 = recursive
            return nodeCopy
        }
        return nil
    }

    public func XMLNode() -> xmlNodePtr? {
        return xmlNode_
    }

    public func shouldFreeXMLNode() -> Bool {
        return shouldFreeXMLNode_
    }

    public func setShouldFreeXMLNode(_ flag: Bool) {
        shouldFreeXMLNode_ = flag
    }

}

public class GDataXMLElement: GDataXMLNode {

    public init(consumingXMLNode theXMLNode: xmlNodePtr) {
        super.init(xmlNode: theXMLNode, shouldFreeXMLNode: true)
    }

    public init(borrowingXMLNode theXMLNode: xmlNodePtr) {
        super.init(xmlNode: theXMLNode, shouldFreeXMLNode: false)
    }

    public init(xmlString str: String, recoverOnErrors: Bool = false) throws {
        guard let utf8Str = str.cString(using: String.Encoding.utf8) else {
            throw NSError(domain: "com.google.GDataXML", code: -1, userInfo: nil)
        }
        var xmlNode: xmlNodePtr?
        // NOTE: We are assuming a string length that fits into an int
        let flags = recoverOnErrors ? kGDataXMLParseRecoverOptions : kGDataXMLParseOptions
        if let doc = xmlReadMemory(utf8Str, Int32(strlen(utf8Str)), nil, // URL
                                   nil, // encoding
                                   flags) {
            // copy the root node from the doc
            if let root = xmlDocGetRootElement(doc) {
                // 1: recursive
                xmlNode = xmlCopyNode(root, 1)
            }
            xmlFreeDoc(doc)
        }

        if xmlNode == nil {
            // failure
            throw NSError(domain: "com.google.GDataXML", code: -1, userInfo: nil)
        }
        else {
            super.init(xmlNode: xmlNode, shouldFreeXMLNode: true)
        }
    }

    public init(withHTMLString str: String) throws {
        guard let utf8Str = str.cString(using: String.Encoding.utf8) else {
            throw NSError(domain: "com.google.GDataXML", code: -1, userInfo: nil)
        }
        var xmlNode: xmlNodePtr?
        // NOTE: We are assuming a string length that fits into an int
        if let doc = htmlReadMemory(utf8Str, Int32(strlen(utf8Str)), nil, // URL
                                    nil, // encoding
                                    kGDataHTMLParseOptions) {
            // copy the root node from the doc
            if let root = xmlDocGetRootElement(doc) {
                xmlNode = xmlCopyNode(root, 1) // 1: recursive
            }
            xmlFreeDoc(doc)
        }

        if xmlNode == nil {
            // failure
            throw NSError(domain: "com.google.GDataXML", code: -1, userInfo: nil)
        }
        else {
            super.init(xmlNode: xmlNode, shouldFreeXMLNode: true)
        }
    }

    public func namespaces() -> [GDataXMLNode]? {
        var array: [GDataXMLNode]?

        if let safeXmlNode = xmlNode_, safeXmlNode.pointee.nsDef != nil {
            var currNS = safeXmlNode.pointee.nsDef

            // add this prefix/URI to the list, unless it's the implicit xml prefix
            while currNS != nil {
                if xmlStrEqual(currNS!.pointee.prefix, "xml") != 0 {
                    currNS?.withMemoryRebound(to: xmlNode.self, capacity: 1, { currNS_ in
                        let node = GDataXMLNode.nodeBorrowing(xmlNode: currNS_)
                        if array == nil {
                            array = [node]
                        }
                        else {
                            array?.append(node)
                        }
                    })
                }
                currNS = currNS!.pointee.next
            }

        }
        return array
    }

    public func setNamespace(_ namespaces: [GDataXMLNode]) {

        if let safeXmlNode = xmlNode_ {

            self.releaseCachedValues()

            // remove previous namespaces
            if safeXmlNode.pointee.nsDef != nil {
                xmlFreeNsList(xmlNode_!.pointee.nsDef)
                safeXmlNode.pointee.nsDef = nil
            }

            // add a namespace for each object in the array
            for namespaceNode in namespaces {
                namespaceNode.XMLNode()?.withMemoryRebound(to: xmlNs.self, capacity: 1, { ns in
                    _ = xmlNewNs(safeXmlNode, ns.pointee.href, ns.pointee.prefix)
                })
            }

            // we may need to fix this node's own name; the graft point is where
            // the namespace search starts, so that points to this node too
            type(of: self).fixUpNamespaces(forNode: safeXmlNode, graftingToTreeNode: safeXmlNode)
        }
    }

    public func addNamespace(_ namespace: GDataXMLNode) {
        if let safeXmlNode = xmlNode_ {
            self.releaseCachedValues()

            namespace.XMLNode()?.withMemoryRebound(to: xmlNs.self, capacity: 1, { ns in
                xmlNewNs(safeXmlNode, ns.pointee.href, ns.pointee.prefix)

                // we may need to fix this node's own name; the graft point is where
                // the namespace search starts, so that points to this node too
                type(of: self).fixUpNamespaces(forNode: safeXmlNode, graftingToTreeNode: safeXmlNode)
            })
        }
    }

    public func addChild(_ child: GDataXMLNode) {
        if child.kind() == .attributeKind {
            self.addAttribute(child)
            return
        }

        if xmlNode_ != nil {
            self.releaseCachedValues()
            if let childNodeCopy = child.XMLNodeCopy() {

                if xmlAddChild(xmlNode_, childNodeCopy) == nil {

                    // failed to add
                    xmlFreeNode(childNodeCopy)

                }
                else {
                    // added this child subtree successfully; see if it has
                    // previously-unresolved namespace prefixes that can now be fixed up
                    type(of: self).fixUpNamespaces(forNode: childNodeCopy, graftingToTreeNode: xmlNode_!)
                }
            }
        }
    }

    public func remove(child: GDataXMLNode) {
        // this is safe for attributes too
        if xmlNode_ != nil {
            self.releaseCachedValues()
            let node = child.XMLNode()
            xmlUnlinkNode(node)

            // if the child node was borrowing its xmlNodePtr, then we need to
            // explicitly free it, since there is probably no owning object that will
            // free it on dealloc
            if !child.shouldFreeXMLNode() {
                xmlFreeNode(node)
            }
        }
    }

    public func elementsFor(name: String) -> [GDataXMLNode]? {
        let desiredName = name

        if let safeXmlNode = xmlNode_ {

            if let prefix = type(of: self).prefix(forName: desiredName) {

                if let foundNS = xmlSearchNs(safeXmlNode.pointee.doc, safeXmlNode, prefix) {

                    // we found a namespace; fall back on elementsForLocalName:URI:
                    // to get the elements
                    let desiredURI = self.stringFrom(xmlString: foundNS.pointee.href)
                    let localName = type(of: self).localName(forName: desiredName)
                    let nsArray = self.elementsFor(localName: localName, URI: desiredURI)
                    return nsArray
                }

            }

            // no namespace found for the node's prefix; try an exact match
            // for the name argument, including any prefix
            var array: [GDataXMLNode]?

            // walk our list of cached child nodes
            if let children = self.children() {
                for child in children {

                    let currNode = child.XMLNode()

                    // find all children which are elements with the desired name
                    if currNode?.pointee.type == XML_ELEMENT_NODE {

                        let qName = child.name()
                        if qName == name {
                            if array == nil {
                                array = [child]
                            }
                            else {
                                array!.append(child)
                            }
                        }
                    }
                }
            }

            return array
        }
        return nil
    }

    public func elementsFor(localName: String?, URI: String?) -> [GDataXMLNode]? {

        var array: [GDataXMLNode]?

        if let safeXmlNode = xmlNode_, safeXmlNode.pointee.children != nil {
            let fakeQName = GDataFakeQNameFor(URI: URI, name: localName)
            var expectedLocalName = localName

            // resolve the URI at the parent level, since usually children won't
            // have their own namespace definitions, and we don't want to try to
            // resolve it once for every child
            let foundParentNS = xmlSearchNsByHref(safeXmlNode.pointee.doc, safeXmlNode, URI)
            if foundParentNS != nil {
                expectedLocalName = fakeQName
            }

            if let children = self.children() {
                for child in children {

                    let currChildPtr = child.XMLNode()

                    // find all children which are elements with the desired name and
                    // namespace, or with the prefixed name and a null namespace
                    if currChildPtr?.pointee.type == XML_ELEMENT_NODE {

                        // normally, we can assume the resolution done for the parent will apply
                        // to the child, as most children do not define their own namespaces
                        var childLocalNS = foundParentNS
                        var childDesiredLocalName = expectedLocalName

                        if currChildPtr?.pointee.nsDef != nil {
                            // this child has its own namespace definitons; do a fresh resolve
                            // of the namespace starting from the child, and see if it differs
                            // from the resolve done starting from the parent.  If the resolve
                            // finds a different namespace, then override the desired local
                            // name just for this child.
                            childLocalNS = xmlSearchNsByHref(safeXmlNode.pointee.doc, currChildPtr, URI)
                            if childLocalNS != foundParentNS {

                                // this child does indeed have a different namespace resolution
                                // result than was found for its parent
                                if childLocalNS == nil {
                                    // no namespace found
                                    childDesiredLocalName = fakeQName
                                }
                                else {
                                    // a namespace was found; use the original local name requested,
                                    // not a faked one expected from resolving the parent
                                    childDesiredLocalName = localName
                                }
                            }
                        }

                        // check if this child's namespace and local name are what we're
                        // seeking
                        if currChildPtr?.pointee.ns == childLocalNS
                            && currChildPtr?.pointee.name != nil
                            && xmlStrEqual(currChildPtr?.pointee.name, childDesiredLocalName) != 0 {
                            if array == nil {
                                array = [child]
                            }
                            else {
                                array!.append(child)
                            }
                        }
                    }
                }
            }

            // we return nil, not an empty array, according to docs
        }
        return array
    }

    public func attributes() -> [GDataXMLNode]? {

        if cachedAttributes_ != nil {
            return cachedAttributes_
        }

        var array: [GDataXMLNode]?

        if let safeXmlNode = xmlNode_, safeXmlNode.pointee.properties != nil {

            var prop = safeXmlNode.pointee.properties
            while prop != nil {

                prop!.withMemoryRebound(to: xmlNode.self, capacity: 1, { prop_ in
                    let node = GDataXMLNode.nodeBorrowing(xmlNode: prop_)
                    if array == nil {
                        array = [node]
                    }
                    else {
                        array!.append(node)
                    }
                })

                prop = prop!.pointee.next
            }

            cachedAttributes_ = array
        }
        return array
    }

    public func addAttribute(_ attribute: GDataXMLNode) {

        if let safeXmlNode = xmlNode_ {

            self.releaseCachedValues()

            attribute.XMLNode()?.withMemoryRebound(to: xmlAttr.self, capacity: 1, { attrPtr in
                // ignore this if an attribute with the name is already present,
                // similar to NSXMLNode's addAttribute
                var oldAttr: xmlAttrPtr?

                if attrPtr.pointee.ns == nil {
                    oldAttr = xmlHasProp(safeXmlNode, attrPtr.pointee.name)
                }
                else {
                    oldAttr = xmlHasNsProp(safeXmlNode, attrPtr.pointee.name, attrPtr.pointee.ns.pointee.href)
                }

                if oldAttr == nil {

                    var newPropNS: xmlNsPtr?

                    // if this attribute has a namespace, search for a matching namespace
                    // on the node we're adding to
                    if attrPtr.pointee.ns != nil {

                        newPropNS = xmlSearchNsByHref(safeXmlNode.pointee.doc, xmlNode_,
                                attrPtr.pointee.ns.pointee.href)
                        if newPropNS == nil {
                            // make a new namespace on the parent node, and use that for the
                            // new attribute
                            newPropNS = xmlNewNs(safeXmlNode, attrPtr.pointee.ns.pointee.href,
                                    attrPtr.pointee.ns.pointee.prefix)
                        }
                    }

                    // copy the attribute onto this node
                    attrPtr.withMemoryRebound(to: xmlNode.self, capacity: 1, { attrPtr_ in
                        let value = xmlNodeGetContent(attrPtr_)
                        if let newProp = xmlNewNsProp(safeXmlNode, newPropNS, attrPtr_.pointee.name, value) {
                            // we made the property, so clean up the property's namespace

                            newProp.withMemoryRebound(to: xmlNode.self, capacity: 1, { newProp_ in
                                type(of: self).fixUpNamespaces(forNode: newProp_, graftingToTreeNode: safeXmlNode)
                            })
                        }

                        if value != nil {
                            xmlFree(value)
                        }
                    })

                }

            })
        }
    }

    public func attributeFor(xmlNode theXmlNode: xmlAttrPtr) -> GDataXMLNode? {
        // search the cached attributes list for the GDataXMLNode with
        // the underlying xmlAttrPtr
        if let attributes = self.attributes() {
            for attr in attributes {
                if let result = attr.XMLNode()?.withMemoryRebound(to: xmlAttr.self, capacity: 1, { attr_ in
                    return theXmlNode == attr_ ? attr : nil
                }) {
                    return result
                }
            }
        }

        return nil
    }

    public func attribute(forName name: String) -> GDataXMLNode? {

        if let safeXmlNode = xmlNode_ {
            var attrPtr = xmlHasProp(safeXmlNode, name)
            if attrPtr == nil {

                // can we guarantee that xmlAttrPtrs always have the ns ptr and never
                // a namespace as part of the actual attribute name?
                var localName: String? = name

                // split the name and its prefix, if any
                var ns: xmlNsPtr?
                if let prefix = type(of: self).prefix(forName: name) {

                    // find the namespace for this prefix, and search on its URI to find
                    // the xmlNsPtr
                    localName = type(of: self).localName(forName: name)
                    ns = xmlSearchNs(safeXmlNode.pointee.doc, xmlNode_, prefix)
                }

                let nsURI = ns != nil ? ns!.pointee.href : nil
                attrPtr = xmlHasNsProp(xmlNode_, localName, nsURI)
            }

            if attrPtr != nil {
                let attr = self.attributeFor(xmlNode: attrPtr!)
                return attr
            }

        }
        return nil
    }

    public func attributeFor(localName: String, URI attributeURI: String) -> GDataXMLNode? {

        if xmlNode_ != nil {
            var attrPtr = xmlHasNsProp(xmlNode_, localName, attributeURI)

            if attrPtr == nil {
                // if the attribute is in a tree lacking the proper namespace,
                // the local name may include the full URI as a prefix
                let fakeQName = GDataFakeQNameFor(URI: attributeURI, name: localName)
                attrPtr = xmlHasProp(xmlNode_, fakeQName)
            }

            if attrPtr != nil {
                let attr = self.attributeFor(xmlNode: attrPtr!)
                return attr
            }

        }
        return nil
    }

    public func resolvePrefixFor(namespaceURI: String) -> String? {

        if xmlNode_ != nil {
            if let foundNS = xmlSearchNsByHref(xmlNode_!.pointee.doc, xmlNode_, namespaceURI) {

                // we found the namespace
                if foundNS.pointee.prefix != nil {
                    let prefix = self.stringFrom(xmlString: foundNS.pointee.prefix)
                    return prefix
                }
                else {
                    // empty prefix is default namespace
                    return ""
                }
            }

        }
        return nil
    }

    public static func delete(namespace: xmlNsPtr, fromXMLNode node: xmlNodePtr) {

        // utilty routine to remove a namespace pointer from an element's
        // namespace definition list.  This is just removing the nsPtr
        // from the singly-linked list, the node's namespace definitions.
        var currNS = node.pointee.nsDef
        var prevNS: xmlNsPtr?

        while currNS != nil {
            let nextNS = currNS!.pointee.next

            if namespace == currNS {

                // found it; delete it from the head of the node's ns definition list
                // or from the next field of the previous namespace

                if prevNS != nil {
                    prevNS!.pointee.next = nextNS
                }
                else {
                    node.pointee.nsDef = nextNS
                }

                xmlFreeNs(currNS)
                return
            }
            prevNS = currNS
            currNS = nextNS
        }
    }

    public static func fixQualifiedNames(forNode nodeToFix: xmlNodePtr, graftingToTreeNode graftPointNode: xmlNodePtr) {

        // Replace prefix-in-name with proper namespace pointers
        //
        // This is an inner routine for fixUpNamespacesForNode:
        //
        // see if this node's name lacks a namespace and is qualified, and if so,
        // see if we can resolve the prefix against the parent
        //
        // The prefix may either be normal, "gd:foo", or a URI
        // "{http://blah.com/}:foo"

        if nodeToFix.pointee.ns == nil {
            var foundNS: xmlNsPtr?

            let localNameResult = splitQNameReverse(nodeToFix.pointee.name)
            if let localName = localNameResult.qname {
                if let prefix = localNameResult.prefix {

                    // if the prefix is wrapped by { and } then it's a URI
                    let prefixLen = xmlStrlen(localNameResult.prefix)
                    if prefixLen > 2
                        && prefix.advanced(by: 0).pointee == /*'{'*/ 0x7b
                        && prefix.advanced(by: Int(prefixLen) - 1).pointee == /*'}'*/ 0x7d {

                        // search for the namespace by URI
                        if let uri = xmlStrsub(prefix, 1, prefixLen - 2) {
                            foundNS = xmlSearchNsByHref(graftPointNode.pointee.doc, graftPointNode, uri)
                            xmlFree(uri)
                        }
                    }
                }

                if foundNS == nil {
                    // search for the namespace by prefix, even if the prefix is nil
                    // (nil prefix means to search for the default namespace)
                    foundNS = xmlSearchNs(graftPointNode.pointee.doc, graftPointNode, localNameResult.prefix)
                }

                if foundNS != nil {
                    // we found a namespace, so fix the ns pointer and the local name
                    xmlSetNs(nodeToFix, foundNS)
                    xmlNodeSetName(nodeToFix, localName)
                }

                if localNameResult.prefix != nil {
                    xmlFree(localNameResult.prefix)
                }

                xmlFree(localName)
            }
        }
    }

    public static func fixDuplicateNamespaces(forNode nodeToFix: xmlNodePtr,
                                              graftingToTreeNode graftPointNode: xmlNodePtr,
                                              namespaceSubstitutionMap nsMap: inout [xmlNsPtr: xmlNsPtr]) {

        // Duplicate namespace removal
        //
        // This is an inner routine for fixUpNamespacesForNode:
        //
        // If any of this node's namespaces are already defined at the graft point
        // level, add that namespace to the map of namespace substitutions
        // so it will be replaced in the children below the nodeToFix, and
        // delete the namespace record

        if nodeToFix.pointee.type == XML_ELEMENT_NODE {

            // step through the namespaces defined on this node
            var definedNS = nodeToFix.pointee.nsDef
            while definedNS != nil {

                // see if this namespace is already defined higher in the tree,
                // with both the same URI and the same prefix; if so, add a mapping for
                // it
                if let foundNS = xmlSearchNsByHref(graftPointNode.pointee.doc, graftPointNode, definedNS!.pointee.href),
                    foundNS != definedNS
                    && xmlStrEqual(definedNS!.pointee.prefix, foundNS.pointee.prefix) != 0 {

                    // store a mapping from this defined nsPtr to the one found higher
                    // in the tree
                    nsMap[definedNS!] = foundNS

                    // remove this namespace from the ns definition list of this node;
                    // all child elements and attributes referencing this namespace
                    // now have a dangling pointer and must be updated (that is done later
                    // in this method)
                    //
                    // before we delete this namespace, move our pointer to the
                    // next one
                    let nsToDelete = definedNS!
                    definedNS = definedNS!.pointee.next

                    GDataXMLElement.delete(namespace: nsToDelete, fromXMLNode: nodeToFix)

                }
                else {
                    // this namespace wasn't a duplicate; move to the next
                    definedNS = definedNS!.pointee.next
                }
            }
        }

        // if this node's namespace is one we deleted, update it to point
        // to someplace better
        if nodeToFix.pointee.ns != nil {
            if let replacementNS = nsMap[nodeToFix.pointee.ns!] {
                xmlSetNs(nodeToFix, replacementNS)
            }
        }
    }

    public static func fixUpNamespaces(forNode nodeToFix: xmlNodePtr,
                                       graftingToTreeNode graftPointNode: xmlNodePtr,
                                       namespaceSubstitutionMap nsMap: inout [xmlNsPtr: xmlNsPtr]) {

        // This is the inner routine for fixUpNamespacesForNode:graftingToTreeNode:
        //
        // This routine fixes two issues:
        //
        // Because we can create nodes with qualified names before adding
        // them to the tree that declares the namespace for the prefix,
        // we need to set the node namespaces after adding them to the tree.
        //
        // Because libxml adds namespaces to nodes when it copies them,
        // we want to remove redundant namespaces after adding them to
        // a tree.
        //
        // If only the Mac's libxml had xmlDOMWrapReconcileNamespaces, it could do
        // namespace cleanup for us

        // We only care about fixing names of elements and attributes
        if nodeToFix.pointee.type != XML_ELEMENT_NODE && nodeToFix.pointee.type != XML_ATTRIBUTE_NODE { return; }

        // Do the fixes
        self.fixQualifiedNames(forNode: nodeToFix, graftingToTreeNode: graftPointNode)

        self.fixDuplicateNamespaces(forNode: nodeToFix,
                graftingToTreeNode: graftPointNode,
                namespaceSubstitutionMap: &nsMap)

        if nodeToFix.pointee.type == XML_ELEMENT_NODE {

            // when fixing element nodes, recurse for each child element and
            // for each attribute
            var currChild = nodeToFix.pointee.children
            while currChild != nil {
                self.fixUpNamespaces(forNode: currChild!,
                        graftingToTreeNode: graftPointNode,
                        namespaceSubstitutionMap: &nsMap)
                currChild = currChild!.pointee.next
            }

            var currProp = nodeToFix.pointee.properties
            while currProp != nil {
                currProp!.withMemoryRebound(to: xmlNode.self, capacity: 1, { currProp_ in
                    self.fixUpNamespaces(forNode: currProp_,
                            graftingToTreeNode: graftPointNode,
                            namespaceSubstitutionMap: &nsMap)
                })
                currProp = currProp!.pointee.next
            }
        }
    }

    public static func fixUpNamespaces(forNode nodeToFix: xmlNodePtr, graftingToTreeNode graftPointNode: xmlNodePtr) {

        // allocate the namespace map that will be passed
        // down on recursive calls
        var nsMap = [xmlNsPtr: xmlNsPtr]()

        self.fixUpNamespaces(forNode: nodeToFix, graftingToTreeNode: graftPointNode, namespaceSubstitutionMap: &nsMap)
    }

}

func IANAEncodingCStringFromNSStringEncoding(_ encoding: String.Encoding) -> String? {
    #if os(Android) || os(Windows)
        // TODO: SPA-15. Implement CFStringConvertEncodingToIANACharSetName
        // Maybe ICU Charset detection http://userguide.icu-project.org/conversion/detection
        return nil
    #else
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        let ianaCharacterSetName = CFStringConvertEncodingToIANACharSetName(cfEncoding)
        // To avoid brainfuck with encoding of the encoding string, let's just use NSString convenience method
        return ianaCharacterSetName as String?
    #endif
}

public class GDataXMLDocument {
    internal var xmlDoc_: xmlDocPtr?; // strong; always free'd in dealloc
    internal var cacheDict: [XmlCharKey: String]?
    internal var _encoding: String.Encoding?

    public convenience init(xmlString: String) throws {
        try self.init(xmlString: xmlString, encoding: .utf8)
    }

    public convenience init(data: Data) throws {
        try self.init(data: data, encoding: .utf8, recoverOnErrors: false)
    }

    public convenience init(htmlString: String) throws {
        try self.init(htmlString: htmlString, encoding: .utf8)
    }

    public convenience init(xmlString: String, encoding: String.Encoding) throws {
        guard let data = xmlString.data(using: .utf8) else {
            throw NSError(domain: "com.google.GDataXML", code: -1, userInfo: nil)
        }
        try self.init(data: data, encoding: encoding, recoverOnErrors: false)
    }

    public convenience init(htmlString: String, encoding: String.Encoding) throws {
        guard let data = htmlString.data(using: .utf8) else {
            throw NSError(domain: "com.google.GDataXML", code: -1, userInfo: nil)
        }
        try self.init(htmlData: data, encoding: encoding)
    }

    public init(data: Data, encoding: String.Encoding, recoverOnErrors: Bool = false) throws {
        self._encoding = encoding

        let xmlEncoding = IANAEncodingCStringFromNSStringEncoding(encoding)
        // NOTE: We are assuming [data length] fits into an int.
        data.withUnsafeBytes { bytes in
            let bindedBytes = bytes.bindMemory(to: CChar.self).baseAddress
            let flags = recoverOnErrors ? kGDataXMLParseRecoverOptions : kGDataXMLParseOptions
            self.xmlDoc_ = xmlReadMemory(bindedBytes, Int32(data.count), nil, xmlEncoding, flags)
            // TODO(grobbins) map option values
        }

        if xmlDoc_ == nil {
            throw NSError(domain: "com.google.GDataXML", code: -1, userInfo: nil)
            // TODO(grobbins) use xmlSetGenericErrorFunc to capture error
        }
        else {
            self.addStringsCacheToDoc()
        }
    }

    public init(htmlData: Data, encoding: String.Encoding) throws {
        self._encoding = encoding

        let xmlEncoding = IANAEncodingCStringFromNSStringEncoding(encoding)
        // NOTE: We are assuming [data length] fits into an int.
        htmlData.withUnsafeBytes { bytes in
            let bindedBytes = bytes.bindMemory(to: CChar.self).baseAddress
            self.xmlDoc_ = htmlReadMemory(bindedBytes, Int32(htmlData.count), nil, xmlEncoding, kGDataHTMLParseOptions)
            // TODO(grobbins) map option values
        }

        if xmlDoc_ == nil {
            throw  NSError(domain: "com.google.GDataXML", code: -1, userInfo: nil)
            // TODO(grobbins) use xmlSetGenericErrorFunc to capture error
        }
        else {
            self.addStringsCacheToDoc()
        }
    }

    public init(rootElement: GDataXMLElement) {
        xmlDoc_ = xmlNewDoc(nil)
        xmlDocSetRootElement(xmlDoc_, rootElement.XMLNodeCopy())
        self.addStringsCacheToDoc()
    }

    public func addStringsCacheToDoc() {
        // utility routine for init methods
        assert(xmlDoc_ != nil && xmlDoc_!.pointee._private == nil, "GDataXMLDocument cache creation problem")

        // we'll use the user-defined _private field for our cache
        cacheDict = [XmlCharKey: String]()
        xmlDoc_!.pointee._private = withUnsafeMutablePointer(to: &cacheDict) { UnsafeMutableRawPointer($0) }
    }

    deinit {
        if xmlDoc_ != nil {
            // release the strings cache
            //
            // since it's a CF object, were anyone to use this in a GC environment,
            // this would need to be released in a finalize method, too
            xmlDoc_!.pointee._private = nil
            cacheDict = nil

            xmlFreeDoc(xmlDoc_)
        }
    }

    public func rootElement() -> GDataXMLElement? {
        var element: GDataXMLElement?

        if xmlDoc_ != nil {
            if let rootNode = xmlDocGetRootElement(xmlDoc_) {
                element = GDataXMLElement.nodeBorrowing(xmlNode: rootNode) as? GDataXMLElement
            }
        }
        return element
    }

    public func xmlData() -> Data? {
        if xmlDoc_ != nil {
            var buffer: UnsafeMutablePointer<xmlChar>?
            var bufferSize: Int32 = 0

            xmlDocDumpMemory(xmlDoc_, &buffer, &bufferSize)

            if buffer != nil {
                let data = Data(bytes: buffer!, count: Int(bufferSize))
                xmlFree(buffer)
                return data
            }
        }
        return nil
    }

    public func setVersion(_ version: String?) {
        if let safeXmlDoc = xmlDoc_ {
            if safeXmlDoc.pointee.version != nil {
                // version is a const char* so we must cast
                xmlFree(UnsafeMutablePointer<xmlChar>(mutating: safeXmlDoc.pointee.version))
                safeXmlDoc.pointee.version = nil
            }

            if version != nil {
                safeXmlDoc.pointee.version = UnsafePointer<xmlChar>(xmlStrdup(version))
            }
        }
    }

    public func setCharacterEncoding(_ encoding: String?) {
        if let safeXmlDoc = xmlDoc_ {
            if safeXmlDoc.pointee.encoding != nil {
                // encoding is a const char* so we must cast
                xmlFree(UnsafeMutablePointer<xmlChar>(mutating: safeXmlDoc.pointee.encoding))
                safeXmlDoc.pointee.encoding = nil
            }

            if encoding != nil {
                safeXmlDoc.pointee.encoding = UnsafePointer<xmlChar>(xmlStrdup(encoding))
            }
        }
    }

    public func nodes(forXPath XPath: String) throws -> [GDataXMLNode] {
        return try self.nodes(forXPath: XPath, namespaces: nil)
    }

    public func firstNode(forXPath XPath: String) throws -> GDataXMLNode? {
        return try self.nodes(forXPath: XPath).first
    }

    public func nodes(forXPath XPath: String, namespaces: [String: String]?) throws -> [GDataXMLNode] {
        var array: [GDataXMLNode]?
        var errorCode = -1
        var errorInfo = [String: String]()

        if xmlDoc_ != nil {
            if let xpathCtx = xmlXPathNewContext(xmlDoc_) {
                xmlDoc_?.withMemoryRebound(to: xmlNode.self, capacity: 1, { node in
                    xpathCtx.pointee.node = node

                    registerNamespaces(namespaces, xpathCtx, xmlDocGetRootElement(xmlDoc_))

                    // now evaluate the path
                    if let xpathObj = xmlXPathEval(XPath, xpathCtx) {
                        // we have some result from the search
                        array = [GDataXMLNode]()
                        let nodeSet = xpathObj.pointee.nodesetval
                        if !xmlXPathNodeSetIsEmpty(nodeSet) {
                            // add each node in the result set to our array
                            for index in 0..<Int(nodeSet!.pointee.nodeNr) {
                                if let currNode = nodeSet!.pointee.nodeTab.advanced(by: index).pointee {
                                    let node = GDataXMLNode.nodeBorrowing(xmlNode: currNode)
                                    array?.append(node)
                                }
                            }
                        }
                        xmlXPathFreeObject(xpathObj)
                    }
                    else {
                        // provide an error for failed evaluation
                        errorCode = Int(xpathCtx.pointee.lastError.code)
                        if let msg = xpathCtx.pointee.lastError.str1 {
                            let errStr = String(cString: msg)
                            errorInfo = ["error": errStr]
                        }
                    }
                })

                xmlXPathFreeContext(xpathCtx)
            }
        }
        else {
            // not a valid node for using XPath
            errorInfo = ["error": "invalid node"]
        }

        if let array = array {
            return array
        }
        else {
            throw NSError(domain: "com.google.GDataXML", code: errorCode, userInfo: errorInfo)
        }
    }

    public func firstNode(forXPath XPath: String, namespaces: [String: String]) throws -> GDataXMLNode? {
        return try self.nodes(forXPath: XPath, namespaces: namespaces).first
    }

}
