from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify, send_file
from elasticsearch import Elasticsearch, NotFoundError
import time
import uuid
from datetime import datetime
import base64
import io
import mimetypes

app = Flask(__name__)
app.secret_key = "supersecretkey"

# Wait for Elasticsearch with retry logic
max_retries = 30
retry_count = 0
es = None

print("Waiting for Elasticsearch to be ready...")
while retry_count < max_retries:
    try:
        es = Elasticsearch(
            "http://elasticsearch:9200",
            retry_on_timeout=True,
            max_retries=3
        )
        if es.ping():
            print("Successfully connected to Elasticsearch!")
            break
    except Exception as e:
        print(f"Attempt {retry_count + 1}/{max_retries}: {e}")
        time.sleep(2)
        retry_count += 1

if not es or not es.ping():
    print("Failed to connect to Elasticsearch after multiple attempts!")
    # Create a dummy connection for now
    es = Elasticsearch("http://elasticsearch:9200")

USERNAME = "admin"
PASSWORD = "admin"

# Create index with mapping if it doesn't exist
def init_elasticsearch():
    try:
        if not es.indices.exists(index="uploads"):
            es.indices.create(
                index="uploads",
                mappings={
                    "properties": {
                        "filename": {"type": "text"},
                        "content": {"type": "text"},
                        "content_base64": {"type": "text", "index": False},
                        "upload_date": {"type": "date"},
                        "file_size": {"type": "integer"},
                        "mime_type": {"type": "keyword"},
                        "is_binary": {"type": "boolean"}
                    }
                }
            )
            print("Created 'uploads' index successfully!")
    except Exception as e:
        print(f"Error initializing Elasticsearch: {e}")

# Initialize with retry
time.sleep(2)
init_elasticsearch()

def is_text_file(filename, content_bytes):
    """Detect if file is text or binary"""
    # Check by extension first
    text_extensions = {'.txt', '.log', '.json', '.xml', '.csv', '.md', '.py', '.js', '.html', 
                      '.css', '.java', '.cpp', '.c', '.h', '.sh', '.yml', '.yaml', '.ini', 
                      '.conf', '.sql', '.php', '.rb', '.go', '.rs', '.swift', '.kt'}
    
    ext = '.' + filename.rsplit('.', 1)[-1].lower() if '.' in filename else ''
    if ext in text_extensions:
        return True
    
    # Try to decode as text
    try:
        content_bytes.decode('utf-8')
        return True
    except (UnicodeDecodeError, AttributeError):
        return False

@app.route("/", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        if request.form["username"] == USERNAME and request.form["password"] == PASSWORD:
            session["user"] = USERNAME
            return redirect(url_for("home"))
        flash("Invalid credentials", "error")
        return redirect(url_for("login"))

    return render_template("login.html")

@app.route("/home", methods=["GET", "POST"])
def home():
    if "user" not in session:
        return redirect(url_for("login"))

    # Get search query
    search_query = request.args.get("search", "")
    
    # Fetch all documents or search results
    try:
        if search_query:
            # Search in content and filename
            response = es.search(
                index="uploads",
                query={
                    "multi_match": {
                        "query": search_query,
                        "fields": ["content", "filename"]
                    }
                },
                sort=[{"upload_date": {"order": "desc"}}],
                size=100
            )
        else:
            # Get all documents
            response = es.search(
                index="uploads",
                query={"match_all": {}},
                sort=[{"upload_date": {"order": "desc"}}],
                size=100
            )
        
        documents = []
        for hit in response["hits"]["hits"]:
            doc = hit["_source"]
            doc["id"] = hit["_id"]
            documents.append(doc)
    except Exception as e:
        documents = []
        flash(f"Error fetching documents: {str(e)}", "error")

    if request.method == "POST":
        file = request.files.get("file")
        if file and file.filename:
            try:
                content_bytes = file.read()
                mime_type = mimetypes.guess_type(file.filename)[0] or 'application/octet-stream'
                
                # Check if file is text or binary
                is_text = is_text_file(file.filename, content_bytes)
                
                doc_id = str(uuid.uuid4())
                
                if is_text:
                    # Store text files as searchable text
                    content_text = content_bytes.decode('utf-8')
                    es.index(
                        index="uploads",
                        id=doc_id,
                        document={
                            "filename": file.filename,
                            "content": content_text,
                            "upload_date": datetime.utcnow().isoformat(),
                            "file_size": len(content_bytes),
                            "mime_type": mime_type,
                            "is_binary": False
                        }
                    )
                else:
                    # Store binary files as base64
                    content_b64 = base64.b64encode(content_bytes).decode('utf-8')
                    es.index(
                        index="uploads",
                        id=doc_id,
                        document={
                            "filename": file.filename,
                            "content": f"[Binary file: {mime_type}]",
                            "content_base64": content_b64,
                            "upload_date": datetime.utcnow().isoformat(),
                            "file_size": len(content_bytes),
                            "mime_type": mime_type,
                            "is_binary": True
                        }
                    )
                
                flash(f"File '{file.filename}' uploaded successfully!", "success")
                return redirect(url_for("home"))
            except Exception as e:
                flash(f"Error uploading file: {str(e)}", "error")
        else:
            flash("No file selected", "error")

    return render_template("home.html", documents=documents, search_query=search_query)

@app.route("/view/<doc_id>")
def view_document(doc_id):
    if "user" not in session:
        return redirect(url_for("login"))
    
    try:
        doc = es.get(index="uploads", id=doc_id)
        return render_template("view.html", document=doc["_source"], doc_id=doc_id)
    except NotFoundError:
        flash("Document not found", "error")
        return redirect(url_for("home"))
    except Exception as e:
        flash(f"Error: {str(e)}", "error")
        return redirect(url_for("home"))

@app.route("/download/<doc_id>")
def download_document(doc_id):
    if "user" not in session:
        return redirect(url_for("login"))
    
    try:
        doc = es.get(index="uploads", id=doc_id)
        doc_data = doc["_source"]
        
        if doc_data.get("is_binary", False):
            # Decode base64 for binary files
            content_bytes = base64.b64decode(doc_data["content_base64"])
        else:
            # Encode text as bytes
            content_bytes = doc_data["content"].encode('utf-8')
        
        return send_file(
            io.BytesIO(content_bytes),
            as_attachment=True,
            download_name=doc_data["filename"],
            mimetype=doc_data.get("mime_type", "application/octet-stream")
        )
    except NotFoundError:
        flash("Document not found", "error")
        return redirect(url_for("home"))
    except Exception as e:
        flash(f"Error downloading file: {str(e)}", "error")
        return redirect(url_for("home"))

@app.route("/edit/<doc_id>", methods=["GET", "POST"])
def edit_document(doc_id):
    if "user" not in session:
        return redirect(url_for("login"))
    
    try:
        if request.method == "POST":
            filename = request.form.get("filename")
            content = request.form.get("content")
            
            # Get existing document
            existing_doc = es.get(index="uploads", id=doc_id)
            
            # Only allow editing text files
            if existing_doc["_source"].get("is_binary", False):
                flash("Cannot edit binary files. Please download and re-upload.", "error")
                return redirect(url_for("view_document", doc_id=doc_id))
            
            es.update(
                index="uploads",
                id=doc_id,
                doc={
                    "filename": filename,
                    "content": content,
                    "file_size": len(content.encode('utf-8')),
                    "last_modified": datetime.utcnow().isoformat()
                }
            )
            flash(f"Document '{filename}' updated successfully!", "success")
            return redirect(url_for("home"))
        
        doc = es.get(index="uploads", id=doc_id)
        
        # Check if it's a binary file
        if doc["_source"].get("is_binary", False):
            flash("Binary files cannot be edited online. Please download and re-upload.", "error")
            return redirect(url_for("view_document", doc_id=doc_id))
        
        return render_template("edit.html", document=doc["_source"], doc_id=doc_id)
    except NotFoundError:
        flash("Document not found", "error")
        return redirect(url_for("home"))
    except Exception as e:
        flash(f"Error: {str(e)}", "error")
        return redirect(url_for("home"))

@app.route("/delete/<doc_id>", methods=["POST"])
def delete_document(doc_id):
    if "user" not in session:
        return redirect(url_for("login"))
    
    try:
        doc = es.get(index="uploads", id=doc_id)
        filename = doc["_source"].get("filename", "Unknown")
        
        es.delete(index="uploads", id=doc_id)
        flash(f"Document '{filename}' deleted successfully!", "success")
    except NotFoundError:
        flash("Document not found", "error")
    except Exception as e:
        flash(f"Error deleting document: {str(e)}", "error")
    
    return redirect(url_for("home"))

@app.route("/api/stats")
def api_stats():
    if "user" not in session:
        return jsonify({"error": "Unauthorized"}), 401
    
    try:
        count = es.count(index="uploads")
        return jsonify({
            "total_documents": count["count"],
            "index": "uploads"
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/logout")
def logout():
    session.pop("user", None)
    flash("Logged out successfully", "success")
    return redirect(url_for("login"))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
