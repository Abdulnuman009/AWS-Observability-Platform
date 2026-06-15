import { useEffect, useState } from "react";
import UserForm from "./components/UserForm";
import UserTable from "./components/UserTable";
import "./App.css";

function App() {

  const [users, setUsers] = useState([]);

  const loadUsers = async () => {

    const response = await fetch(
      `${process.env.REACT_APP_API_URL}/users`
    );

    const data = await response.json();

    setUsers(data);
  };

  const deleteUser = async (id) => {

    await fetch(
      `${process.env.REACT_APP_API_URL}/users/${id}`,
      {
        method: "DELETE"
      }
    );

    loadUsers();
  };

  useEffect(() => {
    loadUsers();
  }, []);

  return (

    <div className="container">

      <div className="header">

        <h1>AWS Observability Platform</h1>

        <p>
          FastAPI + RDS + Prometheus + Grafana
        </p>

      </div>

      <UserForm onUserAdded={loadUsers}/>

      <UserTable
        users={users}
        onDelete={deleteUser}
      />

    </div>
  );
}

export default App;