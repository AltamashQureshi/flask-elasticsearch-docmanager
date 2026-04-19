#!/bin/bash

set -e

PROJECT="flask-elastic-app"

echo "Creating project structure..."

mkdir -p $PROJECT/app/templates
mkdir -p $PROJECT/nginx
cd $PROJECT

#########################################
# Flask App with Enhanced Features
#########################################

cat > app/app.py << 'EOF'
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
EOF

#########################################
# Requirements
#########################################

cat > app/requirements.txt << 'EOF'
flask
elasticsearch>=8.0.0,<9.0.0
gunicorn
EOF

#########################################
# HTML Templates - Login
#########################################

cat > app/templates/login.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Login - Document Manager</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            justify-content: center;
            align-items: center;
        }
        .login-container {
            background: white;
            padding: 40px;
            border-radius: 10px;
            box-shadow: 0 10px 25px rgba(0,0,0,0.2);
            width: 100%;
            max-width: 400px;
        }
        h2 {
            color: #333;
            margin-bottom: 30px;
            text-align: center;
        }
        .form-group {
            margin-bottom: 20px;
        }
        label {
            display: block;
            margin-bottom: 5px;
            color: #555;
            font-weight: 500;
        }
        input[type="text"], input[type="password"] {
            width: 100%;
            padding: 12px;
            border: 1px solid #ddd;
            border-radius: 5px;
            font-size: 14px;
        }
        input[type="text"]:focus, input[type="password"]:focus {
            outline: none;
            border-color: #667eea;
        }
        button {
            width: 100%;
            padding: 12px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 5px;
            font-size: 16px;
            cursor: pointer;
            font-weight: 600;
        }
        button:hover {
            opacity: 0.9;
        }
        .alert {
            padding: 12px;
            margin-bottom: 20px;
            border-radius: 5px;
            background: #fee;
            color: #c33;
            border: 1px solid #fcc;
        }
    </style>
</head>
<body>
    <div class="login-container">
        <h2>🔐 Document Manager</h2>
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert">{{ message }}</div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        <form method="POST">
            <div class="form-group">
                <label>Username</label>
                <input type="text" name="username" required autofocus>
            </div>
            <div class="form-group">
                <label>Password</label>
                <input type="password" name="password" required>
            </div>
            <button type="submit">Login</button>
        </form>
    </div>
</body>
</html>
EOF

#########################################
# HTML Templates - Home
#########################################

cat > app/templates/home.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Home - Document Manager</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #f5f5f5;
        }
        .navbar {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 15px 30px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .navbar h1 { font-size: 24px; }
        .navbar a {
            color: white;
            text-decoration: none;
            padding: 8px 16px;
            background: rgba(255,255,255,0.2);
            border-radius: 5px;
        }
        .navbar a:hover { background: rgba(255,255,255,0.3); }
        .container {
            max-width: 1200px;
            margin: 30px auto;
            padding: 0 20px;
        }
        .upload-section {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
            margin-bottom: 30px;
        }
        .search-section {
            background: white;
            padding: 20px 30px;
            border-radius: 10px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
            margin-bottom: 30px;
        }
        .search-box {
            display: flex;
            gap: 10px;
        }
        .search-box input {
            flex: 1;
            padding: 12px;
            border: 1px solid #ddd;
            border-radius: 5px;
            font-size: 14px;
        }
        .search-box button {
            padding: 12px 24px;
            background: #667eea;
            color: white;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-weight: 600;
        }
        .file-input-wrapper {
            position: relative;
            display: inline-block;
        }
        input[type="file"] {
            padding: 10px;
            border: 2px dashed #ddd;
            border-radius: 5px;
            width: 100%;
            margin-bottom: 15px;
        }
        button[type="submit"] {
            padding: 12px 30px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            border: none;
            border-radius: 5px;
            cursor: pointer;
            font-weight: 600;
            font-size: 14px;
        }
        button[type="submit"]:hover { opacity: 0.9; }
        .alert {
            padding: 15px;
            margin-bottom: 20px;
            border-radius: 5px;
        }
        .alert.success {
            background: #d4edda;
            color: #155724;
            border: 1px solid #c3e6cb;
        }
        .alert.error {
            background: #f8d7da;
            color: #721c24;
            border: 1px solid #f5c6cb;
        }
        .documents-section {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .documents-section h2 {
            margin-bottom: 20px;
            color: #333;
        }
        .document-count {
            color: #666;
            font-size: 14px;
            margin-bottom: 20px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #eee;
        }
        th {
            background: #f8f9fa;
            font-weight: 600;
            color: #333;
        }
        tr:hover { background: #f8f9fa; }
        .actions {
            display: flex;
            gap: 8px;
        }
        .btn {
            padding: 6px 12px;
            border-radius: 4px;
            text-decoration: none;
            font-size: 12px;
            font-weight: 600;
            border: none;
            cursor: pointer;
        }
        .btn-view {
            background: #17a2b8;
            color: white;
        }
        .btn-edit {
            background: #ffc107;
            color: #333;
        }
        .btn-download {
            background: #28a745;
            color: white;
        }
        .btn-delete {
            background: #dc3545;
            color: white;
        }
        .btn:hover { opacity: 0.8; }
        .no-documents {
            text-align: center;
            padding: 40px;
            color: #999;
        }
        .truncate {
            max-width: 300px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
        }
    </style>
</head>
<body>
    <div class="navbar">
        <h1>📁 Document Manager</h1>
        <a href="/logout">Logout</a>
    </div>

    <div class="container">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert {{ category }}">{{ message }}</div>
                {% endfor %}
            {% endif %}
        {% endwith %}

        <div class="upload-section">
            <h2>📤 Upload New Document</h2>
            <form method="POST" enctype="multipart/form-data">
                <input type="file" name="file" required>
                <button type="submit">Upload File</button>
            </form>
            <p style="margin-top: 10px; color: #666; font-size: 14px;">
                📝 Text files are searchable | 📦 Binary files (images, PDFs, etc.) can be downloaded
            </p>
        </div>

        <div class="search-section">
            <h2>🔍 Search Documents</h2>
            <form method="GET" class="search-box">
                <input type="text" name="search" placeholder="Search in filename or content..." value="{{ search_query }}">
                <button type="submit">Search</button>
                {% if search_query %}
                    <a href="/home" class="btn btn-view">Clear</a>
                {% endif %}
            </form>
        </div>

        <div class="documents-section">
            <h2>📋 Uploaded Documents</h2>
            <div class="document-count">Total: {{ documents|length }} document(s) {% if search_query %}(filtered){% endif %}</div>
            
            {% if documents %}
                <table>
                    <thead>
                        <tr>
                            <th>Filename</th>
                            <th>Type</th>
                            <th>Upload Date</th>
                            <th>Size</th>
                            <th>Content Preview</th>
                            <th>Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        {% for doc in documents %}
                        <tr>
                            <td><strong>{{ doc.filename }}</strong></td>
                            <td>
                                {% if doc.is_binary %}
                                    <span style="background: #6c757d; color: white; padding: 2px 8px; border-radius: 3px; font-size: 11px;">BINARY</span>
                                {% else %}
                                    <span style="background: #28a745; color: white; padding: 2px 8px; border-radius: 3px; font-size: 11px;">TEXT</span>
                                {% endif %}
                            </td>
                            <td>{{ doc.upload_date[:19] if doc.upload_date else 'N/A' }}</td>
                            <td>{{ doc.file_size }} bytes</td>
                            <td class="truncate">{{ doc.content[:100] }}...</td>
                            <td>
                                <div class="actions">
                                    <a href="/view/{{ doc.id }}" class="btn btn-view">View</a>
                                    {% if not doc.is_binary %}
                                        <a href="/edit/{{ doc.id }}" class="btn btn-edit">Edit</a>
                                    {% endif %}
                                    <a href="/download/{{ doc.id }}" class="btn btn-download">Download</a>
                                    <form method="POST" action="/delete/{{ doc.id }}" style="display:inline;" 
                                          onsubmit="return confirm('Are you sure you want to delete this document?');">
                                        <button type="submit" class="btn btn-delete">Delete</button>
                                    </form>
                                </div>
                            </td>
                        </tr>
                        {% endfor %}
                    </tbody>
                </table>
            {% else %}
                <div class="no-documents">
                    <p>{% if search_query %}No documents found matching your search.{% else %}No documents uploaded yet. Upload your first file above!{% endif %}</p>
                </div>
            {% endif %}
        </div>
    </div>
</body>
</html>
EOF

#########################################
# HTML Templates - View
#########################################

cat > app/templates/view.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>View Document</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #f5f5f5;
        }
        .navbar {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 15px 30px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .navbar h1 { font-size: 24px; }
        .navbar a {
            color: white;
            text-decoration: none;
            padding: 8px 16px;
            background: rgba(255,255,255,0.2);
            border-radius: 5px;
        }
        .container {
            max-width: 1000px;
            margin: 30px auto;
            padding: 0 20px;
        }
        .document-view {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .document-meta {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 20px;
        }
        .document-meta p {
            margin-bottom: 10px;
            color: #555;
        }
        .document-meta strong {
            color: #333;
        }
        .document-content {
            background: #f8f9fa;
            padding: 20px;
            border-radius: 5px;
            white-space: pre-wrap;
            word-wrap: break-word;
            font-family: monospace;
            max-height: 600px;
            overflow-y: auto;
        }
        .actions {
            margin-top: 20px;
            display: flex;
            gap: 10px;
        }
        .btn {
            padding: 10px 20px;
            border-radius: 5px;
            text-decoration: none;
            font-weight: 600;
            border: none;
            cursor: pointer;
            display: inline-block;
        }
        .btn-primary {
            background: #667eea;
            color: white;
        }
        .btn-warning {
            background: #ffc107;
            color: #333;
        }
        .btn-success {
            background: #28a745;
            color: white;
        }
        .btn-secondary {
            background: #6c757d;
            color: white;
        }
    </style>
</head>
<body>
    <div class="navbar">
        <h1>📄 View Document</h1>
        <a href="/home">Back to Home</a>
    </div>

    <div class="container">
        <div class="document-view">
            <h2>{{ document.filename }}</h2>
            <div class="document-meta">
                <p><strong>Upload Date:</strong> {{ document.upload_date[:19] if document.upload_date else 'N/A' }}</p>
                <p><strong>File Size:</strong> {{ document.file_size }} bytes</p>
                {% if document.last_modified %}
                <p><strong>Last Modified:</strong> {{ document.last_modified[:19] }}</p>
                {% endif %}
            </div>
            <h3>Content:</h3>
            {% if document.is_binary %}
                <div class="document-content" style="text-align: center; padding: 40px;">
                    <p style="font-size: 18px; color: #666;">📦 Binary File</p>
                    <p style="color: #999; margin-top: 10px;">This is a binary file ({{ document.mime_type }})</p>
                    <p style="color: #999;">Cannot be previewed. Click download to save the file.</p>
                </div>
            {% else %}
                <div class="document-content">{{ document.content }}</div>
            {% endif %}
            
            <div class="actions">
                <a href="/download/{{ doc_id }}" class="btn btn-success">Download File</a>
                {% if not document.is_binary %}
                    <a href="/edit/{{ doc_id }}" class="btn btn-warning">Edit Document</a>
                {% endif %}
                <a href="/home" class="btn btn-secondary">Back to List</a>
            </div>
        </div>
    </div>
</body>
</html>
EOF

#########################################
# HTML Templates - Edit
#########################################

cat > app/templates/edit.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Edit Document</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #f5f5f5;
        }
        .navbar {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 15px 30px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .navbar h1 { font-size: 24px; }
        .navbar a {
            color: white;
            text-decoration: none;
            padding: 8px 16px;
            background: rgba(255,255,255,0.2);
            border-radius: 5px;
        }
        .container {
            max-width: 1000px;
            margin: 30px auto;
            padding: 0 20px;
        }
        .edit-form {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .form-group {
            margin-bottom: 20px;
        }
        label {
            display: block;
            margin-bottom: 8px;
            color: #333;
            font-weight: 600;
        }
        input[type="text"] {
            width: 100%;
            padding: 12px;
            border: 1px solid #ddd;
            border-radius: 5px;
            font-size: 14px;
        }
        textarea {
            width: 100%;
            padding: 12px;
            border: 1px solid #ddd;
            border-radius: 5px;
            font-size: 14px;
            font-family: monospace;
            resize: vertical;
            min-height: 400px;
        }
        .actions {
            display: flex;
            gap: 10px;
        }
        .btn {
            padding: 12px 24px;
            border-radius: 5px;
            font-weight: 600;
            border: none;
            cursor: pointer;
            text-decoration: none;
            display: inline-block;
        }
        .btn-primary {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
        }
        .btn-secondary {
            background: #6c757d;
            color: white;
        }
    </style>
</head>
<body>
    <div class="navbar">
        <h1>✏️ Edit Document</h1>
        <a href="/home">Back to Home</a>
    </div>

    <div class="container">
        <div class="edit-form">
            <form method="POST">
                <div class="form-group">
                    <label>Filename</label>
                    <input type="text" name="filename" value="{{ document.filename }}" required>
                </div>
                <div class="form-group">
                    <label>Content</label>
                    <textarea name="content" required>{{ document.content }}</textarea>
                </div>
                <div class="actions">
                    <button type="submit" class="btn btn-primary">Save Changes</button>
                    <a href="/home" class="btn btn-secondary">Cancel</a>
                </div>
            </form>
        </div>
    </div>
</body>
</html>
EOF

#########################################
# Dockerfile
#########################################

cat > Dockerfile << 'EOF'
FROM python:3.10-slim
WORKDIR /app
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app /app
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "--timeout", "120", "app:app"]
EOF

#########################################
# Nginx Config
#########################################

cat > nginx/default.conf << 'EOF'
server {
    listen 80;
    client_max_body_size 10M;

    location / {
        proxy_pass http://flask:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Increase timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF

#########################################
# .gitignore
#########################################

cat > .gitignore << 'EOF'
__pycache__/
*.pyc
*.pyo
*.pyd
.Python
*.so
*.egg
*.egg-info/
dist/
build/
EOF

#########################################
# README
#########################################

cat > README.md << 'EOF'
# Flask Elasticsearch Document Manager

A full-featured document management system with CRUD operations, search functionality, and Elasticsearch backend.

## Features

- ✅ User Authentication
- ✅ Upload **ANY file type** (text, images, PDFs, documents, archives, etc.)
- ✅ Full-text search across text files
- ✅ Download any uploaded file
- ✅ View document details
- ✅ Edit text file content (binary files can be downloaded and re-uploaded)
- ✅ Delete documents
- ✅ Auto-detection of text vs binary files
- ✅ Responsive UI with modern design
- ✅ Elasticsearch for fast search and storage

## Supported File Types

### Text Files (Searchable & Editable)
- .txt, .log, .json, .xml, .csv, .md
- .py, .js, .html, .css, .java, .cpp, .c, .h
- .sh, .yml, .yaml, .ini, .conf, .sql
- .php, .rb, .go, .rs, .swift, .kt
- Any UTF-8 encoded text file

### Binary Files (Upload & Download)
- Images: .jpg, .png, .gif, .bmp, .svg, .webp
- Documents: .pdf, .docx, .xlsx, .pptx
- Archives: .zip, .tar, .gz, .rar
- Media: .mp3, .mp4, .avi, .mov
- Executables: .exe, .bin, .dll
- Any other file type

## Quick Start

```bash
chmod +x setup.sh
./setup.sh
```

## Access

- URL: http://localhost
- Username: admin
- Password: admin

## How It Works

1. **Text Files**: Stored as searchable text in Elasticsearch
   - Content is indexed and searchable
   - Can be edited directly in the browser
   
2. **Binary Files**: Stored as base64-encoded data
   - Not searchable by content (filename is searchable)
   - Can be downloaded in original format
   - Edit by downloading and re-uploading

## API Endpoints

- GET /api/stats - Get document statistics

## Tech Stack

- Flask (Python web framework)
- Elasticsearch 8.11.0 (Search and storage)
- Nginx (Reverse proxy)
- Docker (Containerization)

## Management

### Stop all containers
```bash
docker stop elasticsearch flask nginx
```

### Start all containers
```bash
docker start elasticsearch flask nginx
```

### View logs
```bash
docker logs flask
docker logs elasticsearch
docker logs nginx
```

### Remove everything
```bash
docker rm -f elasticsearch flask nginx
docker network rm flasknet
docker rmi flask-app
```

## File Size Limits

- Nginx: 10MB max file size (configurable in nginx/default.conf)
- Elasticsearch: Can handle large files via base64 encoding
- Recommended: Keep files under 10MB for optimal performance
EOF

#########################################
# Docker Setup (NO docker-compose)
#########################################

echo ""
echo "======================================"
echo "  Cleaning old containers..."
echo "======================================"
docker rm -f elasticsearch flask nginx 2>/dev/null || true
docker network rm flasknet 2>/dev/null || true

echo ""
echo "======================================"
echo "  Creating Docker network..."
echo "======================================"
docker network create flasknet

#########################################
# Run Elasticsearch
#########################################

echo ""
echo "======================================"
echo "  Starting Elasticsearch..."
echo "======================================"
docker run -d \
  --name elasticsearch \
  --network flasknet \
  -e "discovery.type=single-node" \
  -e "xpack.security.enabled=false" \
  -e "ES_JAVA_OPTS=-Xms512m -Xmx512m" \
  -p 9200:9200 \
  docker.elastic.co/elasticsearch/elasticsearch:8.11.0

echo "Waiting for Elasticsearch to be ready..."
sleep 15

#########################################
# Build Flask Image
#########################################

echo ""
echo "======================================"
echo "  Building Flask image..."
echo "======================================"
docker build -t flask-app .

#########################################
# Run Flask Container
#########################################

echo ""
echo "======================================"
echo "  Starting Flask container..."
echo "======================================"
docker run -d \
  --name flask \
  --network flasknet \
  flask-app

#########################################
# Run Nginx
#########################################

echo ""
echo "======================================"
echo "  Starting Nginx..."
echo "======================================"
docker run -d \
  --name nginx \
  --network flasknet \
  -p 80:80 \
  -v $(pwd)/nginx/default.conf:/etc/nginx/conf.d/default.conf \
  nginx:latest

echo ""
echo "======================================"
echo " 🚀 Application Started Successfully!"
echo "======================================"
echo ""
echo " 🌐 Open: http://localhost"
echo " 👤 Username: admin"
echo " 🔑 Password: admin"
echo ""
echo " Features:"
echo "  ✅ Upload documents"
echo "  ✅ Search documents"
echo "  ✅ View documents"
echo "  ✅ Edit documents"
echo "  ✅ Delete documents"
echo ""
echo " Management Commands:"
echo "  View Flask logs:    docker logs flask"
echo "  View ES logs:       docker logs elasticsearch"
echo "  Stop all:           docker stop elasticsearch flask nginx"
echo "  Start all:          docker start elasticsearch flask nginx"
echo ""
echo "======================================"

