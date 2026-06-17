import logging
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import (
    create_engine,
    Column,
    Integer,
    String,
    text
)
from sqlalchemy.orm import declarative_base
from sqlalchemy.orm import sessionmaker
from dotenv import load_dotenv
import os
from prometheus_fastapi_instrumentator import Instrumentator

load_dotenv()

logging.basicConfig(
    filename="/var/log/fastapi/app.log",
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)

logger = logging.getLogger(__name__)

DB_HOST = os.getenv("DB_HOST")
DB_PORT = os.getenv("DB_PORT")
DB_USER = os.getenv("DB_USER")
DB_PASSWORD = os.getenv("DB_PASSWORD")
DB_NAME = os.getenv("DB_NAME")

# -----------------------------
# Create database if not exists
# -----------------------------

server_url = (
    f"mysql+pymysql://{DB_USER}:{DB_PASSWORD}"
    f"@{DB_HOST}:{DB_PORT}"
)

server_engine = create_engine(server_url)

with server_engine.connect() as conn:
    conn.execute(
        text(f"CREATE DATABASE IF NOT EXISTS {DB_NAME}")
    )
    conn.commit()

# -----------------------------
# App DB Connection
# -----------------------------

DATABASE_URL = (
    f"mysql+pymysql://{DB_USER}:{DB_PASSWORD}"
    f"@{DB_HOST}:{DB_PORT}/{DB_NAME}"
)

engine = create_engine(DATABASE_URL)

SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine
)

Base = declarative_base()

# -----------------------------
# Table Definition
# -----------------------------

class User(Base):
    __tablename__ = "users"

    id = Column(
        Integer,
        primary_key=True,
        index=True
    )

    name = Column(
        String(100),
        nullable=False
    )

    email = Column(
        String(100),
        unique=True,
        nullable=False
    )

# -----------------------------
# FastAPI App
# -----------------------------

app = FastAPI(
    title="AWS Observability Demo API"
)

Instrumentator().instrument(app).expose(app)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # testing only
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# -----------------------------
# Startup Event
# -----------------------------

@app.on_event("startup")
def startup():

    Base.metadata.create_all(bind=engine)

    logger.info("Database initialized")
    logger.info("Users table created")


# -----------------------------
# Health Check
# -----------------------------

@app.get("/")
def root():

    return {
        "status": "healthy",
        "service": "backend-api"
    }


# -----------------------------
# Create User
# -----------------------------

@app.post("/users")
def create_user(user: dict):
    logger.info(f"Creating user: {user['email']}")

    db = SessionLocal()

    try:

        new_user = User(
            name=user["name"],
            email=user["email"]
        )

        db.add(new_user)
        db.commit()
        db.refresh(new_user)

        return {
            "message": "User created",
            "data": {
                "id": new_user.id,
                "name": new_user.name,
                "email": new_user.email
            }
        }

    finally:
        db.close()


# -----------------------------
# Get All Users
# -----------------------------

@app.get("/users")
def get_users():
    logger.info("Fetching all users")

    db = SessionLocal()

    try:

        users = db.query(User).all()

        return users

    finally:
        db.close()


# -----------------------------
# Get User By Id
# -----------------------------

@app.get("/users/{user_id}")
def get_user(user_id: int):

    db = SessionLocal()

    try:

        user = db.query(User).filter(
            User.id == user_id
        ).first()

        if not user:
            raise HTTPException(
                status_code=404,
                detail="User not found"
            )

        return user

    finally:
        db.close()


# -----------------------------
# Update User
# -----------------------------

@app.put("/users/{user_id}")
def update_user(
    user_id: int,
    payload: dict
):

    logger.info(f"Updating user: {user_id}")

    db = SessionLocal()

    try:

        user = db.query(User).filter(
            User.id == user_id
        ).first()

        if not user:
            raise HTTPException(
                status_code=404,
                detail="User not found"
            )

        user.name = payload["name"]
        user.email = payload["email"]

        db.commit()

        return {
            "message": "User updated"
        }

    finally:
        db.close()


# -----------------------------
# Delete User
# -----------------------------

@app.delete("/users/{user_id}")
def delete_user(user_id: int):
    logger.info(f"Deleting user: {user_id}")

    db = SessionLocal()

    try:

        user = db.query(User).filter(
            User.id == user_id
        ).first()

        if not user:
            raise HTTPException(
                status_code=404,
                detail="User not found"
            )

        db.delete(user)
        db.commit()

        return {
            "message": "User deleted"
        }

    finally:
        db.close()