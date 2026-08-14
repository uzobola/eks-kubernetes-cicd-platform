from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/")
def home():
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Challenge Complete</title>
        <style>
            body {
                margin: 0;
                height: 100vh;
                display: flex;
                justify-content: center;
                align-items: center;
                font-family: Arial, sans-serif;
            }

            h1 {
                font-size: 48px;
                font-weight: bold;
                text-align: center;
            }
        </style>
    </head>
    <body>
        <h1>Congratulations Challenge Completed !</h1>
    </body>
    </html>
    """, 200


@app.get("/health")
def health():
    return jsonify(status="healthy"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)