import XCTest
@testable import SwiftGDataXML_HTML

final class SwiftGDataXML_HTMLTests: XCTestCase {

    func testGDataXMLNodeXPathShouldWork() {
        let xml = """
            <doc>
                <node attr="val1"/>
                <node attr="val2"/>
                </doc>
            """

        var error: Error? = nil
        guard let doc = GDataXMLDocument(xmlString: xml, error: &error) else {
            XCTFail(error?.localizedDescription ?? "Document should be created")
            return
        }
        guard let nodes = doc.nodes(forXPath: "//node[@attr=\"val1\"]", error: &error) else {
            XCTFail(error?.localizedDescription ?? "XPath should fidn a node")
            return
        }
        XCTAssertEqual(nodes.count, 1, "There should be only one node found")
        guard let xmlElement = nodes.first as? GDataXMLElement else {
            XCTFail(error?.localizedDescription ?? "Wrong node type")
            return
        }
        let foundValue = xmlElement.attributeFor(name: "attr")?.stringValue()
        XCTAssertEqual(foundValue, "val1")
    }
    
    func testGDataXMLNodeXPathForHTMLShouldWork() {
        let docString = """
            <doc aa>
                <node attr="val1"/>
                <node attr="val2"/>
                <node attr="val3">
                </doc>
            """
        
        var error: Error? = nil
        let badDoc = GDataXMLDocument(xmlString: docString, error: &error)
        XCTAssertNil(badDoc, "String is not valid XML, creating document should fail")
        
        guard let doc = GDataXMLDocument(htmlString: docString, error: &error) else {
            XCTFail(error?.localizedDescription ?? "Document should be created")
            return
        }
        guard let nodes = doc.nodes(forXPath: "//node[@attr=\"val1\"]", error: &error) else {
            XCTFail(error?.localizedDescription ?? "XPath should fidn a node")
            return
        }
        XCTAssertEqual(nodes.count, 1, "There should be only one node found")
        guard let xmlElement = nodes.first as? GDataXMLElement else {
            XCTFail(error?.localizedDescription ?? "Wrong node type")
            return
        }
        let foundValue = xmlElement.attributeFor(name: "attr")?.stringValue()
        XCTAssertEqual(foundValue, "val1")
    }
    
    func testGDataXMLNodeXPathShouldReturnRoot() {
        var error: Error? = nil
        
        // XML
        var doc = GDataXMLDocument(xmlString: "<doc/>", error: &error)
        XCTAssertEqual(doc?.nodes(forXPath: "//doc", error: &error)?.count, 1, "1.1: Works, 1.2: Works")
        XCTAssertEqual(doc?.nodes(forXPath: "/doc", error: &error)?.count, 1, "1.1: Works, 1.2: Works")
        XCTAssertEqual(doc?.nodes(forXPath: "doc", error: &error)?.count, 1, "1.1: Works, 1.2: Fails")
        
        // HTML
        doc = GDataXMLDocument(htmlString: "<doc/>", error: &error)
        XCTAssertEqual(doc?.nodes(forXPath: "//html", error: &error)?.count, 1, "1.1: Works, 1.2: Works")
        XCTAssertEqual(doc?.nodes(forXPath: "/html", error: &error)?.count, 1, "1.1: Fails, 1.2: Fails")
        XCTAssertEqual(doc?.nodes(forXPath: "html", error: &error)?.count, 1, "1.1: Fails, 1.2: Fails")

    }
    
    /*func testNSCrash() {
        let invalidXML = """
            <?xml version="1.0"?> \
                <!DOCTYPE EXAMPLE SYSTEM "example.dtd" [
                                                        <!ENTITY xml "<prefix:node>prefix is indeclared here</prefix:node>">
                                                        ]>
                <EXAMPLE xmlns:prefix="http://example.com">
                &xml;
                </EXAMPLE>
            """
        var error: Error? = nil
        let doc = GDataXMLDocument(xmlString: invalidXML, error: &error)
        guard let rootElement = doc?.rootElement() else {
            XCTFail("No root")
            return
        }
        let data = self.read(rootElement)
        XCTAssertNotNil(data)
    }
    
    func read(_ node: GDataXMLNode) -> [String : Any]? {
        var childs: [[String : Any]] = []
        var content: String? = nil
        if node.children()?.count == 1 && (node.children()?[0])?.kind() == .TextKind {
            if let children = node.children()?[0] {
                content = "\(children)".trimmingCharacters(in: CharacterSet.whitespaces)
            }
        } else {
            node.children()?.forEach { child in
                childs.append(read(child) ?? [:])
            }
        }
        return ["tag": node.name() ?? "", "content": childs.count > 0 ? childs : content != nil ? content! : []]
    }*/

    static var allTests = [
        ("testGDataXMLNodeXPathShouldWork", testGDataXMLNodeXPathShouldWork),
        ("testGDataXMLNodeXPathForHTMLShouldWork", testGDataXMLNodeXPathForHTMLShouldWork),
        ("testGDataXMLNodeXPathShouldReturnRoot", testGDataXMLNodeXPathShouldReturnRoot),
    ]
}
