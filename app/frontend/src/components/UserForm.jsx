import { useState } from "react";

export default function UserForm({ onUserAdded }) {

  const [name, setName] = useState("");
  const [email, setEmail] = useState("");

  const submit = async () => {

    await fetch(`${process.env.REACT_APP_API_URL}/users`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        name,
        email
      })
    });

    setName("");
    setEmail("");

    onUserAdded();
  };

  return (
    <div className="card">

      <h2>Add User</h2>

      <input
        placeholder="Name"
        value={name}
        onChange={(e)=>setName(e.target.value)}
      />

      <input
        placeholder="Email"
        value={email}
        onChange={(e)=>setEmail(e.target.value)}
      />

      <button onClick={submit}>
        Create User
      </button>

    </div>
  );
}